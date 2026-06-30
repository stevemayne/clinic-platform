# Clinic environment template

Copy this directory to onboard a new clinic.

```bash
cp -r envs/_template envs/<clinic>
cd envs/<clinic>
```

Then:

1. **`locals.tf`** — replace `__CLINIC__` with the clinic slug and set `domain_name`. The slug **must equal the directory name** (`name_prefix = basename(path.cwd)`).
2. **`backend.tf`** — set the bucket to the `state_bucket_name` from `scripts/bootstrap` (`tfstate-<clinic>-<account_id>`).
3. Run `scripts/bootstrap` against the clinic's AWS account first (if not done).
4. `terraform init && terraform apply`.
5. Delegate the registrar's NS records to the `name_servers` output.
6. Populate the Secrets Manager placeholders created by `secrets.tf`.

> Find/replace `__CLINIC__` across `locals.tf` and `backend.tf` before the first apply.
