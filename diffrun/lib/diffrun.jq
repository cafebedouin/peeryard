# diffrun.jq: manifest validation, result validation, predicate evaluation and the verdict rule.
# Loaded with: jq -L diffrun/lib 'include "diffrun"; ...'

def ops: ["==", "!=", ">", ">=", "<", "<="];
def pad($n): tostring | . + ([range(0; [$n - length, 0] | max)] | map(" ") | join(""));
def is_op: . as $o | ops | any(. == $o);
def is_posint: type == "number" and . == floor and . >= 1;
def reserved_env: ["WORKDIR", "FC_INNER", "PATH", "HOME", "LD_PRELOAD", "LD_LIBRARY_PATH", "JAVA_HOME", "IFS", "BASH_ENV", "ENV", "DIFFRUN_ROLE", "DIFFRUN_BASE_JAR", "DIFFRUN_CANDIDATE_JAR"];

def cmp($a; $op; $b):
  if   $op == "==" then $a == $b
  elif $op == "!=" then $a != $b
  elif $op == ">"  then $a >  $b
  elif $op == ">=" then $a >= $b
  elif $op == "<"  then $a <  $b
  else                  $a <= $b end;

# ---- manifest ----
# A comparison {key, op, value} against a declared metric; emits error strings.
def check_comparison($m; $c; $where):
  if ($c | type) != "object" then "\($where): must be an object {key, op, value}"
  else
    (($c | keys) - ["key", "op", "value"] | select(length > 0) | "\($where): unknown fields \(tojson)"),
    (if ($c.key | type) != "string" then "\($where): key must be a string"
     else ($m.metrics[$c.key]? // null) as $t
       | if $t == null then "\($where): undeclared metric \($c.key)"
         elif ($c.op | is_op | not) then "\($where): bad op \($c.op | tojson)"
         elif $t == "number" and ($c.value | type) != "number" then "\($where): number metric \($c.key) compared with a \($c.value | type)"
         elif $t == "boolean" and ($c.value | type) != "boolean" then "\($where): boolean metric \($c.key) compared with a \($c.value | type)"
         elif $t == "boolean" and ($c.op != "==" and $c.op != "!=") then "\($where): boolean metric \($c.key) compared with \($c.op) (only == and != allowed)"
         else empty end
     end)
  end;

def check_predicate($m; $p; $where):
  if ($p | type) != "object" then "\($where): predicate must be an object"
  else ([$p | keys[] | select(. == "any" or . == "all" or . == "count")]) as $forms
    | if ($forms | length) != 1 then "\($where): exactly one of any/all/count required"
      elif $forms[0] == "count" then
        (($p | keys) - ["count", "cmp", "k"] | select(length > 0) | "\($where): unknown fields \(tojson)"),
        check_comparison($m; $p.count; "\($where).count"),
        (if ($p.cmp | is_op | not) then "\($where): bad cmp \($p.cmp | tojson)" else empty end),
        (if ($p.k | type) != "number" or $p.k != ($p.k | floor) or $p.k < 0 then "\($where): k must be a non-negative integer" else empty end)
      else
        (($p | keys) - [$forms[0]] | select(length > 0) | "\($where): unknown fields \(tojson)"),
        check_comparison($m; $p[$forms[0]]; "\($where).\($forms[0])")
      end
  end;

def validate_manifest:
  . as $m
  | [ if type != "object" then "manifest must be an object"
      else
        ((keys - ["name", "script", "tier", "env", "metrics", "n", "max_n", "stop_when", "min_valid_runs", "timeout_seconds", "expect", "mixed_jars", "description",
                  "precheck", "precheck_timeout_seconds"])
           | select(length > 0) | "unknown top-level fields \(tojson)"),
        (if (.name | type) != "string" or (.name | test("^[a-z0-9][a-z0-9-]*$") | not) then "name: required, [a-z0-9-]" else empty end),
        (if (.script | type) != "string" or .script == "" then "script: required string" else empty end),
        (if has("precheck") and ((.precheck | type) != "string" or .precheck == "") then "precheck: non-empty string (a script under diffrun/scenarios/)" else empty end),
        (if has("precheck_timeout_seconds") and (.precheck_timeout_seconds | is_posint | not) then "precheck_timeout_seconds: positive integer" else empty end),
        (if has("precheck_timeout_seconds") and (has("precheck") | not) then "precheck_timeout_seconds: needs precheck" else empty end),
        (if (.tier != "public" and .tier != "private") then "tier: must be public or private" else empty end),
        (if (.description? // "" | type) != "string" then "description: must be a string" else empty end),
        (if (.env? // {} | type) != "object" then "env: must be an object"
         else (.env? // {} | to_entries[]
           | if (.key | test("^[A-Z_][A-Z0-9_]*$") | not) then "env.\(.key): bad name"
             elif (.key as $k | reserved_env | any(. == $k)) then "env.\(.key): reserved name"
             elif (.value | type) == "number" then empty
             elif (.value | type) != "string" then "env.\(.key): value must be a string or number, got \(.value | type)"
             elif (.value | test("[\n\r\u0000]")) then "env.\(.key): value contains a newline or NUL"
             else empty end)
         end),
        (if (.metrics | type) != "object" or (.metrics | length) == 0 then "metrics: required non-empty object"
         else (.metrics | to_entries[]
           | if (.key | test("^[A-Za-z_][A-Za-z0-9_]*$") | not) then "metrics.\(.key): bad name"
             elif (.value != "number" and .value != "boolean") then "metrics.\(.key): type must be \"number\" or \"boolean\", got \(.value | tojson)"
             else empty end)
         end),
        (if (.n | is_posint | not) then "n: required positive integer" else empty end),
        (if has("min_valid_runs") and (.min_valid_runs | is_posint | not) then "min_valid_runs: positive integer" else empty end),
        (if has("min_valid_runs") and (.n | is_posint) and (.min_valid_runs | is_posint) and .min_valid_runs > .n then "min_valid_runs: exceeds n" else empty end),
        (if has("max_n") != has("stop_when") then "max_n and stop_when go together (the sequential rule)" else empty end),
        (if has("max_n") and ((.max_n | is_posint | not) or ((.n | is_posint) and .max_n < .n)) then "max_n: positive integer >= n" else empty end),
        (if has("stop_when") then
           (if (.stop_when | type) != "object" or (.stop_when | length) == 0 then "stop_when: non-empty object of per-role predicates"
            else ((.stop_when | keys) - ["base", "candidate"] | select(length > 0) | "stop_when: unknown roles \(tojson)"),
                 (if ($m.metrics | type) != "object" then empty
                  else (.stop_when | keys[]) as $r | check_predicate($m; $m.stop_when[$r]; "stop_when.\($r)") end)
            end)
         else empty end),
        (if has("timeout_seconds") and (.timeout_seconds | is_posint | not) then "timeout_seconds: positive integer" else empty end),
        (if (.expect | type) != "object" then "expect: required object"
         else ((.expect | keys) - ["base", "candidate"] | select(length > 0) | "expect: unknown roles \(tojson)"),
              (["base", "candidate"][] as $r
                | if ($m.expect | has($r) | not) then "expect.\($r): required"
                  elif ($m.metrics | type) != "object" then empty
                  else check_predicate($m; $m.expect[$r]; "expect.\($r)") end)
         end)
      end ];

# ---- one run's RESULT_JSON ----
def validate_result($m):
  . as $r
  | [ if type != "object" then "result must be an object"
      else
        (if .schema_version != 1 then "schema_version must be 1" else empty end),
        (if .scenario != $m.name then "scenario \(.scenario | tojson) != manifest name \($m.name | tojson)" else empty end),
        (if (.versions | type) != "object" or (.versions | length) == 0 then "versions: required non-empty object"
         elif (.versions | all(.[]; type == "string") | not) then "versions: values must be strings" else empty end),
        (if (.metrics | type) != "object" then "metrics: required object"
         else ($m.metrics | to_entries[]
           | .key as $k | .value as $t
           | if ($r.metrics | has($k) | not) then "metric \($k) missing"
             elif ($r.metrics[$k] | type) != $t then "metric \($k) is a \($r.metrics[$k] | type), declared \($t)"
             else empty end)
         end)
      end ];

# ---- predicates and verdict ----
def holds($c): cmp(.[$c.key]; $c.op; $c.value);

# $ms: array of metrics objects from the valid runs of one role.
def eval_predicate($p; $ms):
  if   $p | has("any") then $ms | any(.[]; holds($p.any))
  elif $p | has("all") then ($ms | length) > 0 and ($ms | all(.[]; holds($p.all)))   # `all` of nothing is not a pass
  else ([$ms[] | select(holds($p.count))] | length) as $c | cmp($c; $p.cmp; $p.k) end;

def role_summary($m; $role; $runs):
  [$runs[] | select(.role == $role)] as $r
  | [$r[] | select(.class == "VALID") | .metrics] as $ms
  | { valid: ($ms | length),
      void: ([$r[] | select(.class == "VOID")] | length),
      inconclusive: ([$r[] | select(.class == "INCONCLUSIVE")] | length),
      pass: eval_predicate($m.expect[$role]; $ms) };

# Sequential rule: stop once every stop_when predicate holds over the valid runs so far.
def should_stop($m; $runs):
  [$m.stop_when | to_entries[] | .key as $r | .value as $p
   | eval_predicate($p; [$runs[] | select(.role == $r and .class == "VALID") | .metrics])] | all;

# Precedence: DEGENERATE, then AGAINST, then NULL, else SUPPORTS. DEGENERATE first because too few valid runs
# make any comparison void; AGAINST before NULL because a candidate failure is the finding that matters most.
def decide($pr; $minv):
  if $pr.base.valid < $minv or $pr.candidate.valid < $minv then "DEGENERATE"
  elif ($pr.candidate.pass | not) then "AGAINST"
  elif ($pr.base.pass | not) then "NULL"
  else "SUPPORTS" end;

# ---- the verdict table (table.txt), from a verdict.json ----
def render_table:
  (if .pooled then 18 else 14 end) as $rw
  | "scenario \(.scenario) (\(.tier))   verdict: \(.verdict)   [\({SUPPORTS: (if .expect.base == .expect.candidate then "both roles met the same expectation: an agreement scenario, not a before/after difference" else "the base showed the effect and the candidate did not" end), AGAINST: "the candidate failed its predicate", NULL: "the effect was not reproduced on the base", DEGENERATE: "too few valid runs"}[.verdict] // "")]\(if .same_jar then "   [A/A control: the same jar in both roles; not evidence about a change]" else "" end)\(if .n_overridden and .verdict == "SUPPORTS" then "   [n overridden: not citable]" else "" end)\(if .pooled and .pooled_n_differs and .verdict == "SUPPORTS" then "   [pooled n differs: not citable]" else "" end)",
  "n=\(.n_run) (manifest \(.n_manifest)\(if .n_overridden then ", OVERRIDDEN" else "" end))   min_valid_runs=\(.min_valid_runs)\(if .sequential then "   sequential: min \(.n_min), cap \(.sequential.max_n_effective)\(if .sequential.max_n_effective != .sequential.max_n then " (manifest \(.sequential.max_n), raised by -n)" else "" end), stopped by \(.sequential.stopped_by)" else "" end)\(if .precheck then "   precheck: \(.precheck.script), failed \(.precheck.failed)" else "" end)",
  (if .pooled then "pooled: \(.pooled.shards | length) shards x \(.pooled.pairs_per_shard) pairs = \(.pooled.pairs_dispatched) pairs dispatched   present: \([.pooled.shards[] | select(.present) | .k] | map(tostring) | join(",") | if . == "" then "-" else . end)   lost: \([.pooled.shards[] | select(.present | not) | .k] | map(tostring) | join(",") | if . == "" then "-" else . end)   min_valid_runs source: \(.pooled.min_valid_source)" else empty end),
  "",
  "\("role" | pad(10)) \("valid" | pad(6)) \("void" | pad(5)) \("inconcl" | pad(8)) \("pass" | pad(6)) expect",
  (["base", "candidate"][] as $r | .per_role[$r] as $p
    | "\($r | pad(10)) \($p.valid | pad(6)) \($p.void | pad(5)) \($p.inconclusive | pad(8)) \($p.pass | pad(6)) \(.expect[$r] | tojson)"),
  "",
  "\("run" | pad($rw)) \("class" | pad(32)) \("cause" | pad(28)) metrics",
  (.pooled as $pool | .runs[] | "\("\(if $pool then "\(.shard)/" else "" end)\(.role)-\(.index)" | pad($rw)) \(.class + (if .reason then " (" + .reason + (if .precheck == "fail" then ": precheck" else "" end) + ")" else "" end) | pad(32)) \((.cause // "-") | pad(28)) \(.metrics // {} | tojson)");
