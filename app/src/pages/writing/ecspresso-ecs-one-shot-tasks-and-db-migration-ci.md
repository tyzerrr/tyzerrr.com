---
layout: ../../layouts/MarkdownPostLayout.astro
title: 'ECS one-shot tasks with ecspresso'
pubDate: 2026-06-08
description: 'How I wired ecspresso, ECS one-shot tasks, Secrets Manager and GitHub Actions to run DB user sync and Atlas migrations safely'
author: 'tyzerrr'
---

# ECS one-shot tasks with ecspresso

I recently spent a good amount of time building the operational side of a small AWS project called `aws-log-practice`.

The application itself is not the interesting part here. The interesting part is the infrastructure and deployment workflow around it:

- ECS Fargate
- RDS for PostgreSQL in private subnets
- Secrets Manager
- ECR
- GitHub Actions with OIDC
- Atlas for database migrations
- ecspresso for ECS service deployment and one-shot tasks

The final shape is this:

1. Application and batch images are built in GitHub Actions and pushed to ECR.
2. ECS service deployment is handled by ecspresso.
3. Operational batch jobs run as ECS one-shot tasks.
4. Database migrations are detected in CI, checked for drift, and then applied by an ECS one-shot task.

<span style="color: rgb(74, 222, 128); font-weight: 700;">The key design decision was to never connect to RDS directly from GitHub Actions.</span>

RDS stays private. CI only builds images and asks ECS to run tasks inside the VPC.

## The problem I wanted to solve

I had two operational tasks that needed to touch the database.

The first one was DB application user management.

The app should not use the RDS admin user. It should have its own least-privilege user. That user needs to be created, updated when its password changes, and granted permissions for existing and future tables/sequences.

The second one was database migration.

I wanted GitHub Actions to detect newly added migration files and apply them automatically, but only after checking that the current remote RDS schema still matches what the migration history says it should be.

The obvious but bad approach is:

```text
GitHub Actions runner
  -> connect directly to RDS
  -> run SQL / atlas migrate apply
```

That would force me to make private RDS reachable from CI somehow. I did not want that.

So I flipped the direction.

```text
GitHub Actions runner
  -> build and push an image
  -> ask ECS to run a task
  -> ECS task connects to RDS inside the VPC
```

This is the main idea of the design.

## Why ecspresso

Terraform is already managing the long-lived infrastructure:

- VPC
- subnets
- ALB
- ECS cluster
- ECR repository
- RDS instance
- Secrets Manager secrets
- IAM roles
- CloudWatch Logs
- GitHub Actions OIDC role

At first, it is tempting to also manage every ECS task definition with Terraform.

But one-shot tasks have values that change frequently:

- image URI
- command
- migration base version
- task definition file used for a specific operation

I did not want to run `terraform apply` every time I wanted to deploy an app image or execute a one-shot task.

So I split the responsibilities.

| Tool | Responsibility |
|---|---|
| Terraform | Long-lived AWS infrastructure |
| ecspresso | ECS service deployment and task execution |
| GitHub Actions | Build images, push to ECR, run ecspresso |

ecspresso is especially useful because it can read values from Terraform state.

The config is small:

```yaml
region: ap-northeast-1
cluster: aws-log-practice-dev-ecs-cluster
service: aws-log-practice-dev-ecs-service
service_definition: ecs-service-def.json
task_definition: ecs-task-def.json
timeout: "10m0s"

plugins:
  - name: tfstate
    config:
      url: s3://aws-log-practice-remote-backend-dev/terraform/dev/aws/terraform.state
```

Then task definitions can reference Terraform outputs and resources:

```json
{
  "image": "{{ must_env `IMAGE_URI` }}",
  "environment": [
    {
      "name": "DB_HOST",
      "value": "{{ tfstate `output.db_primary_host` }}"
    },
    {
      "name": "DB_PORT",
      "value": "{{ tfstate `output.db_port` }}"
    },
    {
      "name": "DB_NAME",
      "value": "{{ tfstate `output.primary_db_name` }}"
    }
  ],
  "executionRoleArn": "{{ tfstate `aws_iam_role.task_execution.arn` }}",
  "taskRoleArn": "{{ tfstate `aws_iam_role.task.arn` }}"
}
```

This matters a lot.

I do not need to copy the RDS endpoint, DB port, log group name, IAM role ARN, subnet IDs, or security group IDs into GitHub Actions secrets.

<span style="color: rgb(74, 222, 128); font-weight: 700;">Terraform owns infrastructure values. ecspresso reads them. GitHub Actions only passes the image URI and small runtime parameters.</span>

That is the clean separation I wanted.

## Why ECS one-shot tasks

DB user synchronization and migrations are not services. They do not need to keep running.

They should start, do one thing, log the result, and exit.

That maps naturally to ECS one-shot tasks.

There are four practical reasons I like this approach.

**1. RDS can remain private.**

The task runs in the same VPC as RDS. The RDS security group only needs to allow traffic from the ECS task security group.

**2. Secrets are read at runtime.**

The Docker image does not contain database credentials. GitHub Actions does not receive database passwords. The ECS task role reads Secrets Manager at runtime.

**3. Logs go to CloudWatch Logs.**

The task is short-lived, but the result is still visible in the same logging system as the application.

```json
{
  "logConfiguration": {
    "logDriver": "awslogs",
    "options": {
      "awslogs-group": "{{ tfstate `aws_cloudwatch_log_group.ecs.name` }}",
      "awslogs-region": "ap-northeast-1",
      "awslogs-stream-prefix": "batch/create-db-app-user"
    }
  }
}
```

**4. Operational code is versioned as an image.**

The batch binary, SQL templates, Atlas binary, and migration files are all tied to a specific image tag.

The tag format makes the purpose clear:

```text
app-<short-sha>-<yyyymmddHHMMSS>
batch-create-db-app-user-<short-sha>-<yyyymmddHHMMSS>
batch-migrate-db-<short-sha>-<yyyymmddHHMMSS>
```

## One binary, multiple commands

The batch program has one entrypoint and multiple commands.

```go
func realMain(ctx context.Context) error {
    if len(os.Args) != 2 {
        return fmt.Errorf("usage: batch [create_db_app_user|check_db_app_user|check_db_migration_drift|apply_db_migration]")
    }

    switch os.Args[1] {
    case "create_db_app_user":
        return CreateDBAppUser(ctx)
    case "check_db_app_user":
        return CheckDBAppUser(ctx)
    case "check_db_migration_drift":
        return CheckDBMigrationDrift(ctx)
    case "apply_db_migration":
        return ApplyDBMigration(ctx)
    default:
        return fmt.Errorf("invalid command: %s", os.Args[1])
    }
}
```

Each ECS task definition chooses the command:

```json
{
  "entryPoint": ["/batch"],
  "command": ["create_db_app_user"]
}
```

This keeps the image structure simple. Adding a new operational command means adding a Go function and a task definition.

## Creating and checking the application DB user

The application should use only the app DB credential.

The admin credential is reserved for operational tasks like:

- creating the app DB user
- changing the app DB user's password
- granting permissions
- running migrations

The `create_db_app_user` task does this:

1. Reads the admin credential from Secrets Manager.
2. Reads the app credential from Secrets Manager.
3. Connects to RDS as the admin user.
4. Renders a SQL template.
5. Executes the SQL inside a read-write transaction.

The task definition receives secret IDs, not passwords:

```json
{
  "environment": [
    {
      "name": "DB_ADMIN_CREDENTIAL_ID",
      "value": "{{ must_env `DB_ADMIN_CREDENTIAL_ID` }}"
    },
    {
      "name": "DB_APP_CREDENTIAL_ID",
      "value": "{{ must_env `DB_APP_CREDENTIAL_ID` }}"
    }
  ]
}
```

At runtime, the batch reads `AWSCURRENT` from Secrets Manager:

```go
input := &secretsmanager.GetSecretValueInput{
    SecretId:     aws.String(secretID),
    VersionStage: aws.String("AWSCURRENT"),
}
```

The SQL template is idempotent:

```sql
DO $create_db_app_user$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles
    WHERE rolname = {{ .UsernameLiteral }}
  ) THEN
    CREATE ROLE {{ .UsernameIdent }} WITH LOGIN PASSWORD {{ .PasswordLiteral }};
  ELSE
    ALTER ROLE {{ .UsernameIdent }} WITH LOGIN PASSWORD {{ .PasswordLiteral }};
  END IF;
END
$create_db_app_user$;

GRANT CONNECT ON DATABASE {{ .DatabaseIdent }} TO {{ .UsernameIdent }};
GRANT USAGE ON SCHEMA {{ .SchemaIdent }} TO {{ .UsernameIdent }};
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {{ .SchemaIdent }} TO {{ .UsernameIdent }};
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA {{ .SchemaIdent }} TO {{ .UsernameIdent }};
ALTER DEFAULT PRIVILEGES IN SCHEMA {{ .SchemaIdent }} GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {{ .UsernameIdent }};
ALTER DEFAULT PRIVILEGES IN SCHEMA {{ .SchemaIdent }} GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO {{ .UsernameIdent }};
```

The important part is that it grants permissions for both existing objects and future objects.

<span style="color: rgb(74, 222, 128); font-weight: 700;">After a migration creates new tables or sequences, I rerun `create_db_app_user` to sync existing-object privileges.</span>

Then I run `check_db_app_user`.

That task connects as the application DB user and verifies database, schema, table, and sequence privileges.

A successful run looks like this:

```json
{
  "level": "INFO",
  "msg": "checked db app user privileges",
  "db_name": "aws_log_practice_primary",
  "schema": "public",
  "username": "aws_log_practice_dev_db_app",
  "checks_count": 18
}
```

This is not just a smoke test. It proves the application credential can actually do what the app needs.

## Migration workflow

Migration is more sensitive than normal application deployment.

I wanted CI to apply migrations automatically, but not blindly.

The workflow is:

1. Detect newly added migration files.
2. Reject changes to existing migration files.
3. Build and push a migration image.
4. Run drift check in ECS.
5. Apply migrations in ECS only if drift check passes.

Here is the simplified GitHub Actions structure:

```yaml
jobs:
  detect_new_migrations:
    runs-on: ubuntu-latest
    outputs:
      has_added_migration: ${{ steps.detect.outputs.has_added_migration }}
      base_version: ${{ steps.detect.outputs.base_version }}
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - id: detect
        run: scripts/detect-new-migrations.sh "${BASE_REF}" "${GITHUB_SHA}"

  migrate-db:
    needs: [detect_new_migrations]
    if: ${{ needs.detect_new_migrations.outputs.has_added_migration == 'true' || inputs.force_run == true }}
    steps:
      - name: Build and push migration image
        uses: docker/build-push-action@v7
        with:
          context: .
          file: server/cmd/batch/Dockerfile.migration
          platforms: linux/amd64
          push: true

      - name: Check DB migration drift
        working-directory: ecspresso
        run: |
          ecspresso run \
            --config ecspresso.config.yaml \
            --task-def migration/ecs-check-db-migration-drift-task-def.json \
            --wait

      - name: Apply DB migration
        working-directory: ecspresso
        run: |
          ecspresso run \
            --config ecspresso.config.yaml \
            --task-def migration/ecs-apply-db-migration-task-def.json \
            --wait
```

`DB_ADMIN_CREDENTIAL_ID` is hardcoded in the workflow:

```yaml
env:
  AWS_REGION: ap-northeast-1
  ECR_REPOSITORY: aws-log-practice-dev-ecr-repository
  DB_ADMIN_CREDENTIAL_ID: aws-log-practice/dev/db/admin
```

That is fine because it is not a credential. It is the name of a Secrets Manager secret.

The actual password is read by the ECS task at runtime.

## Detecting migration changes

The migration detection script intentionally allows only new migration files.

It inspects Git diff status under `db/migrations`:

```bash
git diff --name-status "${base_ref}" "${head_ref}" -- db/migrations
```

Only `A` is accepted.

Changes like `M`, `D`, `R`, or `C` fail the workflow.

That rule exists because applied migration files should be immutable. If a migration file already applied to RDS is edited in Git, the repository and the actual database history no longer tell the same story.

The script also calculates `MIGRATION_BASE_VERSION`.

For drift check, I want to compare:

```text
remote RDS schema now
vs
shadow database with all migrations except the newly added ones
```

So the script subtracts newly added migration files and takes the latest remaining version:

```bash
comm -23 \
  <(git ls-files 'db/migrations/*.sql' | sort) \
  <(printf '%s\n' "${ADDED_MIGRATIONS[@]}" | sort) |
  sed -E 's#^.*/([0-9]+)_.+$#\1#' |
  sort |
  tail -n 1
```

That version becomes `MIGRATION_BASE_VERSION`.

## Drift check with a shadow database

The drift check task has two containers:

- `check-db-migration-drift`
- `shadow-postgres`

The batch container waits for the shadow database to become healthy:

```json
{
  "dependsOn": [
    {
      "condition": "HEALTHY",
      "containerName": "shadow-postgres"
    }
  ]
}
```

The batch then prepares two local databases inside the sidecar PostgreSQL container:

- `shadow`
- `shadow_dev`

It applies migrations up to `MIGRATION_BASE_VERSION` to `shadow`.

```go
if cfg.MigrationBaseVersion != "" {
    _, err := runAtlas(ctx, cfg.AtlasPath,
        "migrate",
        "apply",
        "--url", cfg.ShadowDatabaseURL,
        "--dir", migrationDirURL(cfg.MigrationDir),
        "--to-version", cfg.MigrationBaseVersion,
    )
    if err != nil {
        return err
    }
}
```

Then it compares remote RDS with the shadow database:

```go
diff, err := runAtlas(ctx, cfg.AtlasPath,
    "schema",
    "diff",
    "--from", targetURL,
    "--to", cfg.ShadowDatabaseURL,
    "--dev-url", cfg.DevDatabaseURL,
    "--schema", cfg.Schema,
    "--exclude", "atlas_schema_revisions",
    "--format", "{{ sql . }}",
)
if strings.TrimSpace(diff) != "" {
    return fmt.Errorf("database schema drift detected")
}
```

<span style="color: rgb(74, 222, 128); font-weight: 700;">If drift exists, migration apply stops.</span>

That is the safety gate.

When drift exists, the log contains the SQL diff:

```sql
-- Drop "orders" table
DROP TABLE "public"."orders";
-- Drop "stocks" table
DROP TABLE "public"."stocks";
```

At that point, a human should inspect why the remote schema differs from migration history.

## Migration image

The migration image includes:

- batch binary
- Atlas binary
- `atlas.hcl`
- `db/schema.sql`
- `db/migrations`

The Dockerfile looks like this:

```dockerfile
FROM golang:1.26.4 AS builder
WORKDIR /src/server/cmd/batch

COPY server/cmd/batch/go.mod server/cmd/batch/go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download -x

COPY server/cmd/batch/ ./
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build -o /artifacts/batch ./

FROM debian:13-slim AS atlas
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
RUN curl -sSf https://atlasgo.sh | sh -s -- -y --no-install -o /usr/local/bin/atlas \
    && chmod +x /usr/local/bin/atlas

FROM debian:13-slim
WORKDIR /app

COPY --from=builder /artifacts/batch /batch
COPY --from=atlas /usr/local/bin/atlas /usr/local/bin/atlas
COPY atlas.hcl /app/atlas.hcl
COPY db/schema.sql /app/db/schema.sql
COPY db/migrations /app/db/migrations

CMD ["/batch"]
```

I actually hit this error once:

```text
fork/exec /usr/local/bin/atlas: permission denied
```

The fix was simple:

```dockerfile
RUN curl -sSf https://atlasgo.sh | sh -s -- -y --no-install -o /usr/local/bin/atlas \
    && chmod +x /usr/local/bin/atlas
```

This is the kind of operational failure that is easy to debug when task logs are centralized in CloudWatch Logs.

## IAM boundaries

There are three separate IAM identities involved.

**GitHub Actions OIDC role**

- Push images to ECR
- Read Terraform state from S3
- Register ECS task definitions
- Run ECS tasks
- Deploy ECS services
- Read CloudWatch Logs during ecspresso execution

**ECS task execution role**

- Pull images from ECR
- Write container logs to CloudWatch Logs
- Inject task definition secrets when needed

**ECS task role**

- Read admin/app DB secrets from Secrets Manager at runtime

One important point:

<span style="color: rgb(74, 222, 128); font-weight: 700;">An ECS task does not need an IAM permission like "RDS write" to run SQL against PostgreSQL.</span>

It needs network access to RDS and valid database credentials.

Database authorization is handled by PostgreSQL roles and grants, not IAM.

## CI/CD shape

The final CI/CD shape is:

```text
GitHub Actions
  ├─ detect migration changes
  ├─ build image with buildx
  ├─ push image to ECR
  └─ ecspresso run
       ├─ read Terraform state
       ├─ register ECS task definition
       └─ run ECS task in private subnet
            ├─ read Secrets Manager at runtime
            ├─ connect to private RDS
            ├─ write logs to CloudWatch Logs
            └─ exit 0 or 1
```

For the backend application image, the workflow is similar:

```text
GitHub Actions
  ├─ build backend image
  ├─ push app-<short-sha>-<timestamp> to ECR
  └─ ecspresso deploy
```

Batch and app images share one ECR repository, but the tag prefix makes the type obvious:

```text
aws-log-practice-dev-ecr-repository:app-c1d5db9-20260607143000
aws-log-practice-dev-ecr-repository:batch-create-db-app-user-a4b8d7f-20260607121122
aws-log-practice-dev-ecr-repository:batch-migrate-db-5602045-20260607135231
```

## Lessons learned

I hit a few concrete issues while building this.

**`ecr:GetAuthorizationToken` requires resource `*`.**

ECR login failed with:

```text
not authorized to perform: ecr:GetAuthorizationToken on resource: *
```

That action cannot be scoped to a single repository ARN.

**Secrets Manager runtime reads belong to the task role.**

If the container process calls Secrets Manager, the permission belongs on the ECS task role, not only the task execution role.

**ECS health check retries have a limit.**

I initially set the `shadow-postgres` health check retries to 12. ECS rejected the task definition. The value had to be 10 or less.

**AWS environment variables can override `AWS_PROFILE`.**

I saw `InvalidAccessKeyId` even though I passed `AWS_PROFILE=taichi-aws-log-practice`.
The cause was stale `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, or `AWS_SESSION_TOKEN` in the shell environment.

Unsetting them fixed it.

## What I like about the result

The design is not complicated once the responsibility boundaries are clear.

- Terraform creates long-lived infrastructure.
- ecspresso turns Terraform state into ECS task definitions.
- GitHub Actions builds images and starts ECS operations.
- Secrets Manager values are read only at runtime.
- RDS stays in private subnets.
- Migration apply is gated by drift check.

<span style="color: rgb(74, 222, 128); font-weight: 700;">Instead of moving CI closer to the database, I moved the database operation into ECS, where the database already is.</span>

That is the core idea.

There are still things I want to improve.

The ecspresso task definitions have some duplication. The task role could also be split into application, batch, and migration roles for stricter least privilege.

But the current setup already gets the important parts right:

- no DB password in Git
- no DB password in Docker build
- no DB password in GitHub Actions
- no public RDS access
- migration drift check before apply
- operational logs in CloudWatch Logs

For this project, that is a good foundation.
