---
layout: ../../layouts/MarkdownPostLayout.astro
title: 'Zero-downtime RDS credential rotation'
pubDate: 2026-06-04
description: 'Rotating RDS credentials with Secrets Manager, read replicas and ECS without downtime'
author: 'tyzerrr'
---

# Rotating RDS credentials without downtime

I started from an AWS blog post that shows how to [rotate an RDS master password with Secrets Manager when you have read replicas](https://aws.amazon.com/jp/blogs/database/automate-amazon-rds-credential-rotation-with-aws-secrets-manager-for-primary-instances-with-read-replicas/).
The idea is: keep the master password in Secrets Manager as a self-managed secret, and let a Lambda function rotate it on a schedule.

It looks clean, but the moment you put a real application in front of it, a problem shows up.
This post is the result of digging into that problem until it actually held together.

## The problem: the rotation gap

The AWS blog uses **single-user rotation**: there is one database user, and the Lambda just changes its password in place.

The rotation Lambda always runs four steps:

| Step | What it does |
|---|---|
| `createSecret` | create a new version of the secret (`AWSPENDING`) with a fresh password |
| `setSecret`    | change the password in the database |
| `testSecret`   | connect with the new password to make sure it works |
| `finishSecret` | promote `AWSPENDING` to `AWSCURRENT` |

The trouble is the window between `setSecret` (the database password has already changed) and the moment the application starts using the new value. In that window, any **new** database connection made with the old password fails.

For a single application user that is also shared as the master user, you cannot perfectly synchronize "the database password changed" with "the app started using the new credential." That desync is the whole problem.

## Why "managed master password" does not save you here

The obvious fix is to stop self-managing and let RDS do it: `manage_master_user_password = true`. RDS generates the password, stores it in Secrets Manager, rotates it automatically, and Terraform never sees the value. Great for keeping secrets out of your Terraform state.

But it does not fit this architecture for two concrete reasons.

**1. Read replicas.** For PostgreSQL / MySQL, the replica uses physical replication, so its master password must match the primary exactly. You cannot have the replica manage its own password. Creating a read replica from a source that manages credentials with Secrets Manager fails with:

```
InvalidParameterValue: ManageMasterUserPassword isn't supported for read replicas
```

(SQL Server is the exception.) The replica *can* still work by inheriting the parent's credentials — you set `manage_master_user_password = false` on the replica — but it is friction, and the Terraform AWS provider has had ordering bugs around exactly this.

**2. ECS does not pick up rotations.** When you reference a Secrets Manager secret from an ECS task definition, the ECS agent fetches the value **once at task launch** and injects it as an environment variable. It never refreshes. So after any rotation — managed or not — the running tasks hold a stale password, and new connections fail until you redeploy.

Both of these come back to the same root cause.

## The real insight: stop rotating the password the app shares

Both problems exist because the **master password is being rotated and also used by the application**. Split them:

- **Master / admin user** — created once, used *only* by the rotation Lambda, never by the app. Because the app never touches it, ECS staleness is irrelevant for it.
- **Application user(s)** — a separate, least-privilege user. This is what rotates frequently and what the app actually connects with.

Once you separate them:

- The **ECS staleness** problem is now only about the *app user*, and we solve it deliberately (below).
- The **read-replica limitation** does not apply to the app user at all — `CREATE USER` / `ALTER USER ... PASSWORD` replicates physically to the replicas, so the app user simply exists on the replicas too.

## Alternating users, explained properly

This is the part that took me a while to actually understand, so let me be concrete.

In **alternating users** rotation there is still **one secret**, but its contents hold *both* a username and a password — and the username itself alternates on every rotation.

```
secret "app/db"
{
  "username": "app_user",   <- this changes too, every rotation
  "password": "xxxxxxxx"
}
```

There are two database users with identical permissions:

- `app_user` — the one you create
- `app_user_clone` — created by the Lambda on the first rotation

The rule is dead simple: **every rotation only touches the user that is *not* currently active, then flips which one is active.**

```
Initial
  secret -> app_user / pw_A          (app uses this)
  DB: app_user(pw_A), app_user_clone(pw_old)

--- rotation #1 (active = app_user, so update the OTHER one) ---
  1. generate pw_B for app_user_clone
  2. ALTER app_user_clone PASSWORD = pw_B   (app_user / pw_A is NOT touched)
  3. test connect as app_user_clone / pw_B
  4. promote secret -> app_user_clone / pw_B

After #1
  secret -> app_user_clone / pw_B    (what the app will pick up next)
  app_user / pw_A is STILL VALID     (it was not touched this round)

--- rotation #2 (active = app_user_clone, so update app_user) ---
  ... same thing, the other way around ...
```

The key property: **the user the app is currently using is never the one being rotated.** So there are always two valid sets of credentials, and the previously-active one stays valid until the *next* rotation.

This is what makes a redeploy graceful — more on that next.

A few requirements come with it:

- You need a **separate admin/superuser secret** so the Lambda can clone users and change other users' passwords.
- **Halve your rotation schedule** — each user is only updated every other rotation, so a "90-day" policy means scheduling rotation every 45 days.
- **RDS Proxy does not support alternating users.** If you use RDS Proxy, you are back to single-user plus retries.

## Putting it together: detect rotation → redeploy → no errors

I deliberately *do* want a redeploy on rotation (I keep using env-var injection, so a redeploy is how new tasks get the new value). The flow:

```
Secrets Manager rotation succeeds
        │  (CloudTrail: RotationSucceeded)
        ▼
EventBridge rule  ──►  Lambda  ──►  ecs:UpdateService --force-new-deployment
```

You can also call `UpdateService` directly from the rotation Lambda's `finishSecret` step. Either way, the redeploy must fire **after** `finishSecret`, so new tasks inject the new `AWSCURRENT`.

Now watch why there are **no connection errors** during the rolling deploy, given alternating users:

```
Right after rotation completes:
  new tasks  -> launch with app_user_clone / pw_B  (new CURRENT)  -> OK
  old tasks  -> still using app_user / pw_A
                pw_A was NOT touched this rotation -> STILL VALID
                so even NEW connections from old tasks succeed
```

This is the subtle bit I got wrong at first. It is **not** that "old tasks stop opening new connections." Old tasks are draining in-flight requests and may very well open new DB connections. The reason it is safe is that **the old user is still valid**, so those new connections succeed anyway.

For the redeploy itself to be graceful you still need the usual ECS/ALB hygiene:

- **Capacity overlap** — `minimumHealthyPercent = 100`, `maximumPercent = 200`, so new tasks become healthy *before* old ones are stopped.
- **Connection draining** — ALB target group `deregistration_delay` so in-flight requests finish.
- **Graceful shutdown** — on `SIGTERM`: stop accepting new work, drain in-flight, **close the DB pool**, exit. Set `stopTimeout` long enough.
- **Health checks that exercise the DB** so only tasks that can actually connect receive traffic.

With all of that in place: new tasks come up on the new credential, old tasks drain on the *still-valid* old credential, and you need **no application-side retry and no cache refresh** for the rotation itself.

The one honest caveat: if a new task connects to a **read replica** with the freshly-rotated credential, there is a tiny window where the password change has not replicated yet. A light exponential backoff (a couple of retries) on replica connections makes this bulletproof. For primary connections it is not needed.

## Terraform: keep the secret values out of state

The other goal was to never hardcode credentials and never leave them in Terraform state. Rules that get you there:

- **Never pass a password through Terraform.** `aws_db_instance.password` and `random_password` both land in state in plaintext.
- For the **master**, `manage_master_user_password = true` is the only clean way to have RDS *not* receive a plaintext password from Terraform at all. The replica is created with `manage_master_user_password = false` and inherits.
- For the **app user**, let Terraform manage only the *box* — the secret and its rotation config — and let the rotation Lambda own the value.

```hcl
resource "aws_db_instance" "primary" {
  identifier                    = "app-db"
  engine                        = "postgres"
  username                      = "dbadmin"
  manage_master_user_password   = true                 # no password in state
  master_user_secret_kms_key_id = aws_kms_key.db.arn
}

resource "aws_db_instance" "replica" {
  identifier                  = "app-db-replica"
  replicate_source_db         = aws_db_instance.primary.identifier
  manage_master_user_password = false                  # inherit from primary
}

resource "aws_secretsmanager_secret" "app_db" {
  name       = "app/db/credentials"
  kms_key_id = aws_kms_key.db.arn
}

resource "aws_secretsmanager_secret_rotation" "app_db" {
  secret_id           = aws_secretsmanager_secret.app_db.id
  rotation_lambda_arn = aws_lambda_function.rotator.arn
  rotation_rules { automatically_after_days = 30 }
}

# If you must seed an initial value, never let Terraform fight the Lambda over it:
resource "aws_secretsmanager_secret_version" "app_db" {
  secret_id     = aws_secretsmanager_secret.app_db.id
  secret_string = jsonencode({ username = "app_user", password = "PLACEHOLDER" })
  lifecycle { ignore_changes = [secret_string] }
}
```

Creating the app user and seeding its real password belongs in a migration/bootstrap step, not in Terraform. And regardless of all this, keep the state backend on S3 with SSE-KMS and least-privilege access — ARNs and connection metadata are still sensitive.

## Summary

- Single-user rotation has a gap between "password changed" and "app uses new password." For a shared master user you cannot close it cleanly.
- Managed master password keeps state clean and is great for the **master**, but it does not let read replicas manage their own password, and it does nothing about ECS env-var staleness.
- The fix is to **separate the master user from the application user**. The master is Lambda-only (so ECS staleness is irrelevant) and RDS-managed (so it stays out of state). The app user rotates independently and replicates fine to read replicas.
- **Alternating users** keeps two valid credentials at all times by only ever rotating the *inactive* user. That is what makes a rotation-triggered ECS redeploy graceful: new tasks use the new credential, old tasks drain on the still-valid old credential — no app-side retry, no cache refresh required (a light retry only for read-replica replication lag).
- Watch out for: RDS Proxy not supporting alternating users, and halving your rotation schedule.

The thing I keep coming back to: the answer was not a cleverer Terraform trick. It was separating *who rotates* from *who connects*.
