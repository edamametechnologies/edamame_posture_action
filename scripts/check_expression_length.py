#!/usr/bin/env python3
"""Fail when a step's `run` script would break GitHub's expression limit.

A `run` script that holds a `${{ }}` expression is evaluated as one
`format()` expression, and GitHub rejects the step at run time when that
expression exceeds 21000 characters ("Exceeded max expression length").
Nothing reports it earlier: action 1.2.0's install step failed that way in
every consumer workflow until its inputs moved to `env:`. This check runs on
every push, with a margin under the limit.

Usage: check_expression_length.py action.yml .github/workflows/*.yml
"""
import sys

import yaml

LIMIT = 20000


def steps_of(document):
    if not isinstance(document, dict):
        return
    runs = document.get("runs")
    if isinstance(runs, dict):
        for index, step in enumerate(runs.get("steps") or []):
            yield f"runs.steps[{index}]", step
    for job_name, job in (document.get("jobs") or {}).items():
        if isinstance(job, dict):
            for index, step in enumerate(job.get("steps") or []):
                yield f"jobs.{job_name}.steps[{index}]", step


def main(paths):
    failures = 0
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            document = yaml.safe_load(handle)
        for where, step in steps_of(document):
            script = step.get("run") if isinstance(step, dict) else None
            if not isinstance(script, str) or "${{" not in script:
                continue
            if len(script) > LIMIT:
                name = step.get("name", "")
                print(
                    f"{path}: {where} ({name!r}): run script with ${{{{ }}}} is "
                    f"{len(script)} characters (limit {LIMIT}); move the "
                    "expressions to env: and reference the variables"
                )
                failures += 1
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
