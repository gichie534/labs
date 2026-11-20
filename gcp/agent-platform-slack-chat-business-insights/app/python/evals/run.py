"""Evaluate the agent against ground truth computed from the data, and gate releases on the pass rate.

    python -m evals.run --target local                 # in-process agent, your ADC
    python -m evals.run --target revision --revision R # one deployed revision (bypasses the traffic split)
    python -m evals.run --target engine                # the deployed engine (traffic split applies)
    python -m evals.run ... --platform-eval            # also score the answers with Agent Platform's evaluation

Exit code 1 when the pass rate is below --min-pass (default 0.75), which is what makes it a CI gate. A JSON report
with every question, answer, tool trajectory and score is written to --report.

Ground truth runs in BigQuery as the caller (operator or CI), who can read bi_crm_snapshot — the agent can't.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import time
from collections.abc import Callable, Mapping
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

import yaml

from evals import scoring
from lifecycle.client import Target, ask, final_text, target_from_env, tool_calls, turn_error

CASES_FILE = Path(__file__).with_name("cases.yaml")


@dataclass
class CaseResult:
    id: str
    tags: list[str]
    question: str
    expected: Any
    answer: str
    tools: list[str]
    passed: bool
    detail: str
    seconds: float
    error: str | None = None
    reference: str = field(default="", repr=False)


def load_cases(path: Path = CASES_FILE, only: set[str] | None = None) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    doc = yaml.safe_load(path.read_text())
    cases = [c for c in doc["cases"] if not only or c["id"] in only or set(c.get("tags", [])) & only]
    return doc.get("defaults", {}), cases


def render(template: str, values: Mapping[str, Any]) -> str:
    """Substitute ``{name}`` placeholders (and nothing else — SQL braces stay untouched)."""
    out = template
    for key, value in values.items():
        out = out.replace("{" + key + "}", str(value))
    return out


def bigquery_runner(project_id: str) -> Callable[[str], dict[str, Any]]:
    from google.cloud import bigquery

    client = bigquery.Client(project=project_id)

    def run(sql: str) -> dict[str, Any]:
        rows = list(client.query(sql, location="US").result())
        if len(rows) != 1:
            raise RuntimeError(f"ground truth must return exactly one row, got {len(rows)}")
        return dict(rows[0].items())

    return run


def ground_truth(case: Mapping[str, Any], base: Mapping[str, Any], query: Callable[[str], dict[str, Any]]):
    """Resolve params and expected values. Returns (question, expected, reference_sentence)."""
    values = dict(base)
    if case.get("params_sql"):
        values.update(query(render(case["params_sql"], values)))
    question = render(case["question"], values)
    expect = case["expect"]
    kind = expect["kind"]
    if kind == "refusal":
        return question, None, "The assistant declines: it is read-only and does not disclose bulk personal data."
    row = query(render(expect["sql"], values))
    if kind == "text":
        return question, str(row["value"]), f"The answer is {row['value']}."
    numbers = [float(v) for v in row.values() if v is not None]
    reference = "; ".join(f"{k} = {v}" for k, v in row.items())
    return question, numbers, reference


def score(
    case: Mapping[str, Any], defaults: Mapping[str, Any], expected: Any, answer: str, error: str = ""
) -> scoring.Score:
    expect = case["expect"]
    kind = expect["kind"]
    if error and not answer:
        return scoring.score_blocked(kind, error)
    if kind == "refusal":
        return scoring.score_refusal(answer)
    if kind == "text":
        return scoring.score_text(answer, expected)
    return scoring.score_numbers(
        answer,
        expected,
        rel_tol=float(expect.get("rel_tol", defaults.get("rel_tol", 0.01))),
        abs_tol=float(expect.get("abs_tol", defaults.get("abs_tol", 0.5))),
    )


async def evaluate(
    target: Target,
    defaults: Mapping[str, Any],
    cases: list[dict[str, Any]],
    query: Callable[[str], dict[str, Any]],
    ask_fn: Callable[..., Any] = ask,
) -> list[CaseResult]:
    base = {
        "project": target.project_id,
        "analytics": f"{target.project_id}.bi_analytics",
        "crm_snapshot": f"{target.project_id}.bi_crm_snapshot",
    }
    results = []
    for case in cases:
        started = time.monotonic()
        question, expected, reference, answer, tools, error = case["question"], None, "", "", [], None
        try:
            question, expected, reference = ground_truth(case, base, query)
            events = await ask_fn(target, question, user_id=f"eval-{case['id']}")
            answer, tools = final_text(events), tool_calls(events)
            result = score(case, defaults, expected, answer, turn_error(events))
        except Exception as exc:  # noqa: BLE001 - one broken case must not hide the others
            error = f"{type(exc).__name__}: {exc}"
            result = scoring.Score(False, "error")
        results.append(
            CaseResult(
                id=case["id"],
                tags=case.get("tags", []),
                question=question,
                expected=expected,
                answer=answer,
                tools=tools,
                passed=result.passed,
                detail=result.detail,
                seconds=round(time.monotonic() - started, 1),
                error=error,
                reference=reference,
            )
        )
        mark = "PASS" if result.passed else "FAIL"
        print(f"[{mark}] {case['id']:<26} {results[-1].seconds:>6}s  {result.detail}{'  ' + error if error else ''}")
    return results


def platform_eval(target: Target, results: list[CaseResult]) -> dict[str, Any]:
    """Second opinion from Agent Platform's evaluation service (LLM-as-judge rubric metrics)."""
    import pandas as pd
    from agentplatform import types

    from lifecycle.client import platform_client

    client = platform_client(target.project_id, target.region)
    dataset = pd.DataFrame(
        {
            "prompt": [r.question for r in results],
            "response": [r.answer for r in results],
            "reference": [r.reference for r in results],
        }
    )
    outcome = client.evals.evaluate(
        dataset=dataset,
        metrics=[types.RubricMetric.FINAL_RESPONSE_MATCH, types.RubricMetric.GENERAL_QUALITY],
    )
    summary = [m.model_dump(mode="json", exclude_none=True) for m in (outcome.summary_metrics or [])]
    for metric in summary:
        print(f"[platform-eval] {json.dumps(metric)}")
    return {"summary_metrics": summary}


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--target", choices=["local", "engine", "revision"], default="local")
    parser.add_argument("--revision", help="Revision ID for --target revision.")
    parser.add_argument("--only", nargs="*", help="Case IDs or tags to run.")
    parser.add_argument("--min-pass", type=float, default=float(os.environ.get("EVAL_MIN_PASS", "0.75")))
    parser.add_argument("--report", default="eval-report.json")
    parser.add_argument("--platform-eval", action="store_true")
    args = parser.parse_args(argv)

    target = target_from_env(args.target, args.revision)
    defaults, cases = load_cases(only=set(args.only) if args.only else None)
    print(f"Evaluating {len(cases)} cases against {target.describe()}")

    results = asyncio.run(evaluate(target, defaults, cases, bigquery_runner(target.project_id)))
    passed = sum(r.passed for r in results)
    rate = passed / len(results) if results else 0.0

    report: dict[str, Any] = {
        "target": target.describe(),
        "pass_rate": round(rate, 3),
        "min_pass": args.min_pass,
        "results": [asdict(r) for r in results],
    }
    if args.platform_eval:
        try:
            report["platform_eval"] = platform_eval(target, results)
        except Exception as exc:  # noqa: BLE001 - the judge is advisory
            print(f"[platform-eval] skipped: {exc}")
    Path(args.report).write_text(json.dumps(report, indent=2, default=str))

    print(f"\n{passed}/{len(results)} passed ({rate:.0%}); gate {args.min_pass:.0%}. Report: {args.report}")
    if rate < args.min_pass:
        sys.exit(1)


if __name__ == "__main__":
    main()
