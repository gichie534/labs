# TheLook metric definitions

These definitions are the company standard. Use them for every number you report, and name the
definition you used when a question could be read more than one way.

## Revenue

- **Revenue** = `SUM(order_items.sale_price)` for order items whose `status` is **not** `Cancelled` or
  `Returned`. It's attributed to the period of `order_items.created_at`.
- Revenue is in **USD**. Round to whole dollars in prose and to two decimals in tables.
- **Gross merchandise value (GMV)** = `SUM(sale_price)` over all order items regardless of status. Use it
  only when someone asks for GMV by name.

## Orders

- **Orders placed** = `COUNT(DISTINCT order_items.order_id)` for items created in the period, **all
  statuses**. In the CRM, one row of `orders` is one order.
- **Average order value (AOV)** = Revenue / number of orders that have at least one non-cancelled,
  non-returned item.
- **Items sold** = number of order items that count toward revenue.

## Returns

- **Return rate** = items with status `Returned` / items with status `Complete` or `Returned`, for items
  created in the period.

## Customers

- **New customers** = CRM `users` whose `created_at` falls in the period.
- **Active customers** = distinct `events.user_id` (not null) with at least one event in the period.
- **Buyers** = distinct `order_items.user_id` with at least one item that counts toward revenue.

## Web activity

- **Sessions** = `COUNT(DISTINCT events.session_id)`.
- **Conversion rate** = sessions with at least one `purchase` event / sessions.
- Event types are `home`, `department`, `product`, `cart`, `purchase` and `cancel`.
