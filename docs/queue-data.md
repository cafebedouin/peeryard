# Review-queue data

The review-queue pages are also published as data, for anyone tracking duplicate pull requests, issue claims or merges
by hand or with a tool:

- `https://cafebedouin.github.io/peeryard/queue.json`: the current state.
- `https://cafebedouin.github.io/peeryard/history/index.json`: the dates for which a daily snapshot exists, and
  `history/<date>.json` for each one (from 2026-10-19 on).

**What it is.** A hint for maintainers, not a verdict. Two pull requests in one group made the same change, or work on
the same issue; which one to keep, and whether either is right, is the maintainers' decision. The data comes from public
GitHub data only, read by `queue/build.py` under `queue/rules.json`; every author is treated the same way.

**When it changes.** The queue workflow (`.github/workflows/queue.yml`) runs daily at 06:17 UTC, on a push to main that
changes `queue/`, a `patches.json` or the workflow itself, and on a manual dispatch. A snapshot is per UTC day: a second run on one day replaces that day's file.

**Stability.** Fields are added, not renamed or removed without notice. A change that renames or removes a field
raises `schema_version` and is announced in this file. Ignore fields you do not know.

## `queue.json`

| field | type | meaning |
| --- | --- | --- |
| `schema_version` | int | 1 |
| `generated` | string | `YYYY-MM-DD HH:MM UTC`, when the build ran |
| `generated_at` | string | the same, ISO 8601 (`YYYY-MM-DDTHH:MM:SSZ`) |
| `repo` | string | `ergoplatform/ergo` |
| `open_prs` | int | open pull requests GitHub listed, drafts included |
| `same_change` | list | groups of open pull requests (drafts included) that make the same production change, below |
| `same_issue` | list | groups of open pull requests by different authors on the same issue, below |
| `same_change_error` | string or null | why the duplicate view was not computed on this run (both lists are then empty); null when it was |
| `same_change_uncompared` | list of int | pull requests whose diff could not be read on this run, so they are in no group |
| `min_changed_lines` | int | the smallest change (added plus removed production lines) that can form a `same_change` group |
| `needs_review`, `needs_maintainer` | list of int | the two ranked tracks of the pages, in rank order |
| `carried` | list | upstream pull requests peeryard carries as patches |
| `rows` | list | one object per open, non-draft pull request, below |

**`same_change[]`**: `{patch_id, prs, files, changed_lines}`. `prs` (list of int) is earliest opened first; the first
is the one the others repeat. `patch_id` (string) is `git patch-id --stable` of the production diff, `git diff -U0
<merge-base> <head> -- 'src/main/*' '*/src/main/*'`, from the merge base with the pull request's base branch to its
head. Only changed lines go in (no context lines, no line numbers), so one change made on two different bases has one
id. Tests, docs and the base branch may differ inside a group. `files` (list of string) are the production files of
the first pull request; `changed_lines` (int) counts its added plus removed production lines.

**`same_issue[]`**: `{issue, title, state, url, prs, pairs}`. `issue` (int) is an issue (GitHub says it is not a pull
request) referenced as `#N` or by link in the title or body of two or more open pull requests by different authors that
change at least one of the same production files. `pairs` is a list of `{prs: [int, int], shared_files: int}`; `prs`
is every member, earliest opened first. A pair already in one `same_change` group is not repeated, and a pull request
from a release branch is left out (it references every pull request in the release).

**`rows[]`**, the fields for duplicates (the others are the pages' ranking inputs and may be read the same way):

| field | type | meaning |
| --- | --- | --- |
| `number`, `title`, `author`, `url`, `base` | | the pull request |
| `head_sha` | string | first 9 hex digits of its head commit |
| `production_patch_id` | string or null | the `-U0` id above; null when it changes no production file |
| `production_patch_id_context` | string or null | the same with the default three lines of context: equal ids mean the same change on the same surrounding code |
| `production_changed_lines` | int or null | added plus removed production lines |
| `production_files` | list of string or null | production files changed; null when the diff could not be read |
| `same_change_as` | int | present on a later member of a `same_change` group: the first one |
| `same_change_later` | list of int | present on the first member of a group: the later ones |
| `same_issue` | list | present when in a `same_issue` group: `{issue, with: [int]}` per issue |

Draft pull requests are not in `rows` but are in the groups.

## `history/`

`history/index.json`: `{schema_version, repo, dates, latest, path}`, `dates` oldest first.

`history/<date>.json`: `{schema_version, date, generated_at, repo, open_prs, open_ready_prs, same_change,
same_issue, same_change_error, same_change_uncompared}`. `open_ready_prs` counts open, non-draft pull requests;
`same_change[]` is `{patch_id, prs, files, changed_lines}` with `files` as a count; `same_issue[]` is `{issue, prs,
pairs}` with each pair as `[int, int]`. A group that disappears from one day to the next was closed, merged, or changed;
the pull requests' own pages say which.

The Pages deploy replaces the whole site on every run, so each run reads the snapshots so far back from the published
site before writing today's. If a day the index lists cannot be read, the run fails and the previous site stays up; a
shorter history is never published over a longer one.
