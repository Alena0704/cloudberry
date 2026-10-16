# ----------------------------------------------------------------------
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# ----------------------------------------------------------------------

"""Handle /retest-failed using trusted default-branch code only."""

import json
import os
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode, quote
from urllib.request import Request, urlopen


WORKFLOWS = {
    f".github/workflows/{name}.yml"
    for name in (
        "build-cloudberry", "build-dbg-cloudberry", "build-deb-cloudberry",
        "apache-rat-audit",
    )
}


class GitHub:
    def __init__(self):
        self.base = os.environ["GITHUB_API_URL"] + "/repos/" + os.environ["GITHUB_REPOSITORY"]

    def request(self, path, method="GET"):
        request = Request(self.base + path, method=method, headers={
            "Authorization": "Bearer " + os.environ["GH_TOKEN"],
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        with urlopen(request, timeout=30) as response:
            body = response.read()
            return json.loads(body) if body else None

    def runs(self, sha):
        page = 1
        while True:
            query = urlencode({"event": "pull_request", "head_sha": sha,
                               "per_page": 100, "page": page})
            runs = self.request("/actions/runs?" + query)["workflow_runs"]
            yield from runs
            if len(runs) < 100:
                break
            page += 1


def matches(run, pr):
    if (run["event"] != "pull_request" or run["path"] not in WORKFLOWS
            or run["head_sha"] != pr["head"]["sha"]):
        return False
    # GitHub may omit pull_requests for runs originating from forks.
    if run.get("pull_requests"):
        return any(p["number"] == pr["number"] for p in run["pull_requests"])
    return (run.get("head_repository") is not None
            and pr["head"].get("repo") is not None
            and run["head_repository"]["id"] == pr["head"]["repo"]["id"]
            and run["head_branch"] == pr["head"]["ref"])


def handle(event, api):
    comment = event.get("comment", {})
    if (event.get("action") != "created" or not event.get("issue", {}).get("pull_request")
            or comment.get("body") != "/retest-failed"
            or comment.get("user", {}).get("type") != "User"):
        return ["Ignored: not a /retest-failed PR comment from a user."]
    number = event["issue"]["number"]
    pr = api.request(f"/pulls/{number}")
    if pr["state"] != "open":
        return ["Ignored: the PR is closed."]
    # PR authorship or public read access alone does not authorize retries.
    login = quote(comment["user"]["login"], safe="")
    try:
        permission = api.request(f"/collaborators/{login}/permission")["permission"]
    except HTTPError as error:
        if error.code != 404:
            raise
        permission = "none"
    if permission not in {"write", "maintain", "admin"}:
        try:
            # Unlike a public repository's "read" permission, this endpoint
            # confirms actual collaborator membership, including team access.
            api.request(f"/collaborators/{login}")
        except HTTPError as error:
            if error.code != 404:
                raise
            return ["Denied: repository collaborator or write access is required."]

    # Select the newest run per workflow BEFORE filtering its status. Never
    # resurrect an old failure when a newer run succeeded or is still running.
    latest = {}
    for run in api.runs(pr["head"]["sha"]):
        if matches(run, pr):
            previous = latest.get(run["path"])
            if previous is None or run["id"] > previous["id"]:
                latest[run["path"]] = run

    messages = []
    for candidate in latest.values():
        # Re-read both objects in case a new commit or retry arrived meanwhile.
        current_pr = api.request(f"/pulls/{number}")
        if (current_pr["state"] != "open"
                or current_pr["head"]["sha"] != pr["head"]["sha"]
                or current_pr["base"]["ref"] != pr["base"]["ref"]):
            messages.append("Stopped: the PR changed; post a new command after CI completes.")
            break
        run = api.request(f"/actions/runs/{candidate['id']}")
        if (not matches(run, current_pr) or run["status"] != "completed"
                or run["conclusion"] not in {"failure", "timed_out"}
                or run["updated_at"] > comment["created_at"]):
            continue
        # This endpoint retries only failed jobs and their dependents, keeping
        # the original PR run's permissions and fork approval boundary.
        try:
            api.request(f"/actions/runs/{run['id']}/rerun-failed-jobs", "POST")
            messages.append(f"Requested failed-job retry: {run['html_url']}")
        except HTTPError as error:
            messages.append(f"Could not retry run {run['id']}: GitHub returned HTTP {error.code}.")
    return messages or ["No eligible failed CI runs for the current PR commit."]


if __name__ == "__main__":
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    messages = handle(event, GitHub())
    print("\n".join(messages))
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write("## /retest-failed\n\n" + "\n\n".join(messages) + "\n")
