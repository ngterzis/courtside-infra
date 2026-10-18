# courtside-infra

Terraform infrastructure-as-code for **Courtside** — a full-stack application deployed on AWS. This repo provisions the entire production environment: networking, database, serverless compute, CDN, DNS/TLS, and the CI/CD plumbing that lets the application repos deploy themselves.

## Related repositories

- **[courtside](https://github.com/ngterzis/courtside)** — frontend (React SPA, served from S3 behind CloudFront)
- **[courtside-backend](https://github.com/ngterzis/courtside-backend)** — backend (FastAPI, packaged as a container image and run on Lambda)

## Architecture

```
                              Route 53
                                 │  courtside.<domain>
                                 ▼
                          ┌─────────────┐
   viewer ──────────────▶ │  CloudFront │ (ACM cert in us-east-1)
                          └──────┬──────┘
              /*  │  /api/*  │  /api/chat*
                  ▼          ▼          ▼
            ┌─────────┐  ┌────────┐  ┌──────────────┐
            │   S3    │  │  API   │  │ Lambda chat  │
            │ (SPA)   │  │Gateway │  │ Function URL │
            └─────────┘  └───┬────┘  │(RESPONSE_    │
                             ▼       │  STREAM)     │
                       ┌──────────┐  └──────┬───────┘
                       │  Lambda  │         │
                       │   api    │◀────────┘  (same image)
                       └────┬─────┘
                            │ RDS Data API
                            ▼
                    ┌────────────────┐
                    │ Aurora Postgres│  Serverless v2 (scale-to-zero)
                    │   Serverless   │
                    └────────────────┘
```

### Modules

| Module | What it provisions |
| --- | --- |
| `modules/vpc` | VPC, public/private subnets across two AZs, internet gateway, route tables. No NAT gateway (removed to cut cost — the migration task runs in a public subnet with a public IP). |
| `modules/database` | Aurora PostgreSQL Serverless v2 cluster (scale-to-zero), HTTP endpoint for the RDS Data API, and Secrets Manager secrets for both the Data API credentials and the direct connection URL. |
| `modules/compute` | ECR repository, two Lambda functions (`api` behind API Gateway, `chat` behind a streaming Function URL — both from the same container image via the Lambda Web Adapter), the ECS/Fargate task definition that runs DB migrations, and the GitHub Actions OIDC role used by the backend repo. |
| `modules/frontend` | S3 bucket for the static SPA plus the CloudFront Origin Access Control that fronts it. |
| `modules/cdn` | CloudFront distribution with three origins (S3, API Gateway, chat Function URL), the ACM certificate (us-east-1) with DNS validation, Route 53 alias record, and standard access logging to S3. |

### How it fits together

- **Backend** is built into a container image, pushed to ECR by the `courtside-backend` CI, and run as two Lambda functions sharing that image — `api` for standard request/response traffic and `chat` for SSE streaming through a `RESPONSE_STREAM` Function URL. The Lambda Web Adapter lets the FastAPI app run unmodified.
- **Frontend** is built by the `courtside` CI, synced to S3, and served through CloudFront, which also reverse-proxies `/api/*` to API Gateway and `/api/chat*` to the streaming Function URL — so the SPA and API share one origin and there is no CORS to manage.
- **Database** is Aurora Serverless v2 scaled to zero. The Lambdas reach it over the RDS Data API (no VPC wiring needed); the Fargate migration task connects directly using the URL secret.
- **CI/CD**: this repo and both application repos authenticate to AWS via GitHub Actions OIDC (no long-lived keys). Application CI updates Lambda code and runs the migration task directly; infra changes flow through the Terraform workflow below.

## Layout

```
envs/
  prod/          # the production root module (backend config, providers, wiring)
modules/
  vpc/
  database/
  compute/
  frontend/
  cdn/
.github/
  workflows/
    terraform.yml
```

## Usage

State is stored in S3 (`courtside-app-terraform-state`, key `prod/terraform.tfstate`).

```bash
cd envs/prod

terraform init

terraform plan \
  -var="jwt_secret=..." \
  -var="anthropic_api_key=..." \
  -var="hosted_zone_name=example.com"

terraform apply
```

### Required variables

| Variable | Description |
| --- | --- |
| `hosted_zone_name` | Root domain registered in Route 53 (e.g. `example.com`). The `courtside` subdomain is derived from it. |
| `jwt_secret` | Secret used by the backend to sign/verify JWTs (sensitive). |
| `anthropic_api_key` | API key for the Claude-powered chat feature (sensitive). |
| `langfuse_public_key` / `langfuse_secret_key` | Optional [Langfuse](https://langfuse.com) keys for chat tracing, feedback scores and evals. Empty (the default) leaves tracing off. |
| `langfuse_host` | Langfuse region endpoint. Defaults to `https://cloud.langfuse.com` (EU). |
| `github_repo` | `org/repo` allowed to assume the backend deploy role. Defaults to `ngterzis/courtside-backend`. |
| `aws_region` | Defaults to `eu-central-1`. |

## CI/CD

`.github/workflows/terraform.yml` runs on every push and pull request to `main`:

- **Pull request** → `terraform plan`, with the plan posted back as a PR comment.
- **Push to `main`** → `terraform apply`.

The workflow authenticates with AWS via OIDC (`AWS_INFRA_ROLE_ARN`) and reads `jwt_secret`, `anthropic_api_key`, `hosted_zone_name` and the optional `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` from GitHub Actions secrets.

## Requirements

- Terraform `>= 1.10`
- AWS provider `~> 5.0`
- A domain hosted in Route 53
- Docker available locally on first apply (used to seed a placeholder ECR image so the Lambdas can be created before CI pushes the real one)

## License

[MIT](./LICENSE)
