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

"""Offline tests: python3 -m unittest discover -s .github/scripts -v"""

import copy
import unittest
from urllib.error import HTTPError

from retest_failed import handle


class FakeGitHub:
    def __init__(self):
        self.pr = {
            "number": 7, "state": "open", "user": {"id": 10},
            "head": {"sha": "current", "ref": "feature", "repo": {"id": 20}},
            "base": {"ref": "main"},
        }
        self.run = {
            "id": 100, "event": "pull_request",
            "path": ".github/workflows/build-cloudberry.yml",
            "head_sha": "current", "head_branch": "feature",
            "head_repository": {"id": 20}, "pull_requests": [],
            "status": "completed", "conclusion": "failure",
            "updated_at": "2026-10-01T10:00:00Z", "html_url": "https://example.test/run/100",
        }
        self.items = [self.run]
        self.permission = "read"
        self.collaborator = True
        self.permission_error = None
        self.posts = []
        self.change_head = False
        self.reads = 0

    def runs(self, sha):
        return self.items

    def request(self, path, method="GET"):
        if method == "POST":
            self.posts.append(path)
            return None
        if path.startswith("/pulls/"):
            self.reads += 1
            pr = copy.deepcopy(self.pr)
            if self.change_head and self.reads > 1:
                pr["head"]["sha"] = "new-commit"
            return pr
        if path.startswith("/collaborators/"):
            if self.permission_error:
                raise HTTPError(path, self.permission_error, "Unavailable", {}, None)
            if path.endswith("/permission"):
                return {"permission": self.permission}
            if not self.collaborator:
                raise HTTPError(path, 404, "Not Found", {}, None)
            return None
        return next(run for run in self.items if path == f"/actions/runs/{run['id']}")


class RetestFailedTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeGitHub()
        self.event = {
            "action": "created", "issue": {"number": 7, "pull_request": {}},
            "comment": {"body": "/retest-failed", "created_at": "2026-10-01T11:00:00Z",
                        "user": {"id": 10, "login": "author", "type": "User"}},
        }
        self.event["issue"]["pull_request"] = {"url": "https://example.test/pr/7"}

    def test_read_only_collaborator(self):
        self.event["comment"]["user"]["id"] = 99
        handle(self.event, self.api)
        self.assertEqual(self.api.posts, ["/actions/runs/100/rerun-failed-jobs"])

    def test_roles_that_can_run_ci(self):
        self.event["comment"]["user"]["id"] = 99
        for permission in ("write", "maintain", "admin"):
            with self.subTest(permission=permission):
                api = FakeGitHub()
                api.permission = permission
                api.collaborator = False
                handle(self.event, api)
                self.assertEqual(len(api.posts), 1)

    def test_pr_author_without_repository_access_denied(self):
        self.api.collaborator = False
        self.assertIn("Denied", handle(self.event, self.api)[0])
        self.assertEqual(self.api.posts, [])

    def test_unrelated_read_only_user_denied(self):
        self.event["comment"]["user"]["id"] = 99
        self.api.collaborator = False
        self.assertIn("Denied", handle(self.event, self.api)[0])
        self.assertEqual(self.api.posts, [])

    def test_permission_lookup_errors_never_authorize(self):
        for status in (403, 404, 500):
            with self.subTest(status=status):
                self.api.permission_error = status
                if status == 404:
                    self.assertIn("Denied", handle(self.event, self.api)[0])
                else:
                    with self.assertRaises(HTTPError):
                        handle(self.event, self.api)
                self.assertEqual(self.api.posts, [])

    def test_unrelated_runs_excluded(self):
        for key, value in (("head_sha", "old"), ("event", "push"),
                           ("path", ".github/workflows/untrusted.yml"),
                           ("head_repository", {"id": 999}),
                           ("head_branch", "other"),
                           ("pull_requests", [{"number": 999}])):
            with self.subTest(key=key):
                api = FakeGitHub()
                api.run[key] = value
                handle(self.event, api)
                self.assertEqual(api.posts, [])

    def test_newer_run_prevents_retrying_old_failure(self):
        for status, conclusion in (("completed", "success"), ("in_progress", None),
                                   ("waiting", "action_required")):
            with self.subTest(status=status):
                api = FakeGitHub()
                api.items.append(dict(api.run, id=101, status=status, conclusion=conclusion))
                handle(self.event, api)
                self.assertEqual(api.posts, [])

    def test_no_retry_for_cancelled_or_approval_pending_runs(self):
        for conclusion in ("cancelled", "action_required", "skipped", "success"):
            with self.subTest(conclusion=conclusion):
                self.api.run["conclusion"] = conclusion
                handle(self.event, self.api)
                self.assertEqual(self.api.posts, [])

    def test_new_commit_during_handler(self):
        self.api.change_head = True
        handle(self.event, self.api)
        self.assertEqual(self.api.posts, [])

    def test_stale_command_cannot_repeat_a_newer_attempt(self):
        self.api.run["updated_at"] = "2026-10-01T12:00:00Z"
        handle(self.event, self.api)
        self.assertEqual(self.api.posts, [])

    def test_closed_pr(self):
        self.api.pr["state"] = "closed"
        handle(self.event, self.api)
        self.assertEqual(self.api.posts, [])

    def test_only_exact_new_user_comment(self):
        cases = [dict(self.event, action="edited"), dict(self.event, issue={"number": 7})]
        for body in ("please /retest-failed", "/retest-failed; echo hi"):
            event = copy.deepcopy(self.event)
            event["comment"]["body"] = body
            cases.append(event)
        event = copy.deepcopy(self.event)
        event["comment"]["user"]["type"] = "Bot"
        cases.append(event)
        for event in cases:
            handle(event, self.api)
        self.assertEqual(self.api.posts, [])


if __name__ == "__main__":
    unittest.main()
