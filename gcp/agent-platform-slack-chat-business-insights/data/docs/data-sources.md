# Where the data lives

| Question about | Source | Tables |
|---|---|---|
| Who a customer is (name, email, location, sign-up date) | CRM: Cloud SQL PostgreSQL `crm` | `users` |
| A customer's orders and their status | CRM: Cloud SQL PostgreSQL `crm` | `orders` |
| What customers did on the website | Warehouse: BigQuery `bi_analytics` | `events` |
| Revenue, items, categories, brands, products | Warehouse: BigQuery `bi_analytics` | `order_items`, `products` |

- The two systems share **`user_id`**: `users.id` in the CRM is `events.user_id` and
  `order_items.user_id` in the warehouse. `orders.order_id` in the CRM is `order_items.order_id`.
- No query can join across the two systems. Look the customer up in the CRM first, then query the
  warehouse with their `user_id`.
- "What did customer X do" means their **web events** (by type, by day) and their **orders** (count,
  status, revenue) in the period.

## Privacy

- Use names and email addresses only to identify the one customer a question is about. Never list
  contact details of many customers. For segments, report aggregates.
- Nobody may change data through this assistant. Everything is read-only.
