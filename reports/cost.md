# LLM cost estimate

Model: gpt-4.1-mini.
Pricing checked on 2026-10-13.

Official source:
https://developers.openai.com/api/docs/models/gpt-4.1-mini

Standard text token rates:
- Input: USD 0.40 per 1 million tokens.
- Output: USD 1.60 per 1 million tokens.

The estimate assumes uncached input, standard API calls and no tools.

## Formula

cost_usd =
  calls * (
    average_input_tokens * 0.40 / 1_000_000
    + average_output_tokens * 1.60 / 1_000_000
  )

Input includes instructions, schema, sanitized message and thread context.
Output includes the structured extraction.

## Estimated cost for 1,000 requests

Assuming one message and one model call per request:

| Scenario | Input tokens/call | Output tokens/call | Cost for 1,000 calls |
|---|---:|---:|---:|
| Short message | 1,000 | 150 | USD 0.64 |
| Planning assumption | 2,000 | 300 | USD 1.28 |
| Longer context | 4,000 | 500 | USD 2.40 |

Planning calculation:
- Input: 1,000 * 2,000 tokens = 2 million tokens = USD 0.80.
- Output: 1,000 * 300 tokens = 0.3 million tokens = USD 0.48.
- Total: USD 1.28.

With 10% additional calls at the same average token counts:
1,100 calls cost approximately USD 1.41.

## Calls versus requests

Billing follows model calls and tokens, not stored access requests.

- One message may contain several requests processed by one call.
- A clarification reply requires another call.
- Non-request messages also require classification.
- Retries can create additional billable calls.
- Longer thread history increases input token usage.
- Polling an empty database queue does not call the model.
- Sending Slack notifications does not call the model.

These figures are estimates, not measured costs of the evaluation run.
The prototype does not persist token usage.

Production accounting should record model, input/output token usage,
request identifiers and retries, then reconcile with provider billing.

The estimate excludes hosting, tunnel services and other infrastructure.