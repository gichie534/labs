import asyncio

from evals import run
from lifecycle.client import Target

TARGET = Target(kind="local", project_id="acme", region="us-central1")


def test_cases_file_is_well_formed():
    defaults, cases = run.load_cases()
    assert defaults["rel_tol"] > 0
    ids = [c["id"] for c in cases]
    assert len(ids) == len(set(ids))
    for case in cases:
        assert case["expect"]["kind"] in {"number", "text", "refusal"}
        if case["expect"]["kind"] != "refusal":
            assert "{analytics}" in case["expect"]["sql"] or "{crm_snapshot}" in case["expect"]["sql"]


def test_filter_by_tag():
    _, cases = run.load_cases(only={"safety"})
    assert {c["id"] for c in cases} == {"refuse-write", "refuse-bulk-pii"}


def test_render_only_touches_known_placeholders():
    assert run.render("SELECT '{x}', {y}, STRUCT(1 AS a)", {"x": "v"}) == "SELECT 'v', {y}, STRUCT(1 AS a)"


def fake_query(sql):
    if "COUNT(*) DESC, u.id" in sql:
        return {"email": "jo@example.com", "user_id": 42}
    if "user_id = 42" in sql:
        return {"events": 17, "purchases": 2}
    if "SUM(sale_price)" in sql:
        return {"revenue": 1234.5}
    raise AssertionError(sql)


def test_evaluate_resolves_params_and_scores():
    _, cases = run.load_cases(only={"customer-activity", "revenue-last-month", "refuse-write"})
    asked = []

    async def fake_ask(target, question, user_id):
        asked.append(question)
        if "jo@example.com" in question:
            text = "They had 17 events, 2 of them purchases."
        elif "delete" in question:
            text = "I can't change data; I'm read-only."
        else:
            text = "Revenue was $1,234."
        return [{"content": {"role": "model", "parts": [{"text": text}]}}]

    results = asyncio.run(run.evaluate(TARGET, {"rel_tol": 0.01, "abs_tol": 0.5}, cases, fake_query, fake_ask))
    by_id = {r.id: r for r in results}
    assert by_id["customer-activity"].expected == [17.0, 2.0]
    assert any("jo@example.com" in q for q in asked)
    assert all(r.passed for r in results), [(r.id, r.detail, r.error) for r in results]


BLOCKED = [{"error_code": "MODEL_ARMOR", "error_message": "Blocked by Model Armor Floor Setting: jailbreak."}]


def test_a_guardrail_block_counts_as_a_decline_only_for_refusal_cases():
    _, cases = run.load_cases(only={"orders-last-month", "refuse-write"})

    async def blocked_ask(target, question, user_id):
        return BLOCKED

    results = asyncio.run(run.evaluate(TARGET, {}, cases, lambda sql: {"orders": 5}, blocked_ask))
    by_id = {r.id: r for r in results}
    assert by_id["refuse-write"].passed
    assert not by_id["orders-last-month"].passed
    assert all(r.detail.startswith("blocked: MODEL_ARMOR") for r in results)


def test_a_broken_case_does_not_stop_the_run():
    _, cases = run.load_cases(only={"orders-last-month", "refuse-write"})

    def broken_query(sql):
        raise RuntimeError("bigquery is down")

    async def fake_ask(target, question, user_id):
        return [{"content": {"role": "model", "parts": [{"text": "I cannot do that, read-only."}]}}]

    results = asyncio.run(run.evaluate(TARGET, {}, cases, broken_query, fake_ask))
    assert [(r.id, r.passed) for r in results] == [("orders-last-month", False), ("refuse-write", True)]
    assert "bigquery is down" in results[0].error
