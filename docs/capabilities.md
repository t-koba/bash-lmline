# Capability matrix

What lmline can do with a given authentication mode, endpoint, API format,
model, and search setting. Every cell states one of:

- **supported** — the combination works and is covered by the test suite;
- **unsupported** — the combination is refused, with the reason and the way out;
- **allowed, unverified** — the combination is permitted but needs a real
  account or a real provider, so the offline test suite cannot prove it.

Subscription authentication and native web search are independent
capabilities. A result obtained with an API key never proves that the
subscription path works, and a successful sign-in never proves that native
search works.

## Authentication mode and API format

| Authentication mode | API format | Result |
| --- | --- | --- |
| `api-key` (default) | `chat` | supported |
| `api-key` | `responses` | supported |
| `api-key` | `messages` | supported |
| `chatgpt` | `chat` | unsupported — the subscription route requires `LMLINE_API_FORMAT=responses`; the engine refuses the request before it is sent |
| `chatgpt` | `responses` | supported — the request carries `store: false` and `stream: true`, sends the instructions as `instructions`, and omits `temperature`, `max_output_tokens`, `top_p`, `user`, `metadata`, `background`, `conversation`, and `previous_response_id` |
| `chatgpt` | `messages` | unsupported — the subscription route requires `LMLINE_API_FORMAT=responses` |

The subscription route never falls back to a metered API key. When the
subscription credential is missing or cannot be refreshed, the request fails
with an actionable message instead of billing an API key.

## Authentication mode and endpoint

| Authentication mode | Endpoint | Result |
| --- | --- | --- |
| `api-key` | any OpenAI-compatible base URL | supported |
| `chatgpt` | `https://api.openai.com/v1` | supported |
| `chatgpt` | a loopback proxy (`127.0.0.1`, `localhost`, `::1`) | supported — the token stays on the machine, but the proxy forwards it, so the proxy owner receives it |
| `chatgpt` | any other host | unsupported — the subscription token is only sent to the OpenAI API; the engine refuses the request before it is sent |

## Model

| Model | Result |
| --- | --- |
| a model the endpoint catalog serves | supported |
| a model the endpoint catalog does not serve | unsupported — `lmline model refresh` lists the served models, and `lmline use` rejects an unknown model |
| a model that only a ChatGPT plan serves | allowed, unverified — needs a real ChatGPT account; the offline suite proves the request shape, not the plan access |

## Native web search

| Authentication mode | API format | Search | Result |
| --- | --- | --- | --- |
| `api-key` | any | off (default) | supported |
| `api-key` | `responses` | on | supported — the provider runs the search and bills it; the search tool never reaches the local tool executor |
| `api-key` | `chat` or `messages` | on | unsupported — native web search requires the Responses API format; the engine refuses the request before it is sent |
| `chatgpt` | `responses` | on | allowed, unverified — the subscription route states that web search remains subject to model and account/workspace policy, so it needs a real ChatGPT account |
| `chatgpt` | `responses` | off (default) | supported |
| `chatgpt` | `chat` or `messages` | any | unsupported — the subscription route requires the Responses API format |

Selecting a model never enables search. The search setting is explicit
(`LMLINE_WEB_SEARCH=1`) and off by default.

## Request budget on a paid route

A repeated request can spend the user's plan or repeat a billed search, so:

| Route | Automatic retry | Compatibility retry | Format retry |
| --- | --- | --- | --- |
| `api-key` without search | yes (`LMLINE_HTTP_RETRIES`, default 1) | yes | yes |
| `chatgpt` | no, unless `LMLINE_HTTP_RETRIES` is set explicitly | no | no |
| native search enabled | no, unless `LMLINE_HTTP_RETRIES` is set explicitly | no | no |

A rejected request on a paid route is reported with the provider's reason
instead of being repeated. The request keeps the search tool across the
attempt: it is never silently dropped.

## Usage reporting

The engine reports the token counts the provider returns. A provider that
answers without usage data is reported as unknown, never as zero tokens. The
number of provider-side search calls is reported separately in the engine
metadata line.

## What the offline suite proves

The test suite runs against local mock servers and never contacts a provider.
It proves the request shapes, the refusals, the credential handling, and the
reporting. It cannot prove that a real ChatGPT plan, a real model, or a real
billed search behaves the same way; those cells stay marked as allowed,
unverified.
