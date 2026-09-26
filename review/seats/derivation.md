# Review 1 of 3: read the code first, then judge the findings

You are reviewing a draft review of pull request {{PR}} in {{REPO}}. Do NOT read the draft yet. First read the
pull request's diff and the code it touches (`git -C {{CLONE}} diff {{BASE}}...pr-{{PR}}` and the files it
names) and write, on your own, what you would say about it: what it changes, what invariant it could break,
what you would test. Only then open the draft at {{DRAFT}} and answer, with file:line for every claim, under
three headings **verified / couldn't verify / would cut**: does each finding in the draft stand on the code
alone, without the draft's framing? Is anything in the code the draft missed that matters more? Is any
claim stated as executed that you cannot see evidence for in {{CAPTURES}}? Do not run anything.
