//! santa-grade: grade SANTA actuals written by a runner's `emit` mode with SANTA's comparator, for a base run and
//! for change runs, then list per change the entries that went from failing to passing (fixed), from passing to
//! failing (regressed), that kept pass/fail but changed verdict (for example errored -> panicked), and that kept
//! the verdict but changed output.
//!
//! The verdict of an entry comes from the santa-check library (SANTA's tools/santa-check), with the per-schema
//! dispatch and the red-dimension rule of SANTA's orchestrator (tools/conform/src/main.rs, `tally`): an entry
//! fails when any dimension that `tally` records in a slice's `red` list is coal. Outputs are compared with
//! santa-check's `structural_equal`. Nothing here decides equality on its own.
//!
//! Usage:
//!   santa-grade --vectors <santa>/vectors --runner-json <runner>/runner.json --leaves "<leaf> ..."
//!               --base <dir> [--change <label>=<dir>]... [--control <label>]... [--expected "<leaf>=<n> ..."]
//!               [--json <out.json>] [--summary <out.md>]
//! A label dir holds `actuals/<leaf>/<op>.json` and, optionally, `manifest.json` (written by the build job; a
//! status other than "ok" means the label was not built and is reported, not graded).
//! Exit 0: every control holds. Exit 1: a control failed (or the base could not be graded). Exit 2: usage error.
use santa_check::{
    grade, grade_authds, grade_block, grade_chain, grade_nipopow, grade_transaction, grade_wire, structural_equal,
};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::{env, fs};

fn die(msg: String) -> ! {
    eprintln!("santa-grade: {msg}");
    std::process::exit(2);
}

fn read_json(p: &Path) -> Value {
    let s = fs::read_to_string(p).unwrap_or_else(|e| die(format!("read {}: {e}", p.display())));
    serde_json::from_str(&s).unwrap_or_else(|e| die(format!("parse {}: {e}", p.display())))
}

struct Args {
    vectors: PathBuf,
    runner_json: PathBuf,
    leaves: Vec<String>,
    base: PathBuf,
    changes: Vec<(String, PathBuf)>,
    controls: Vec<String>,
    expected: Option<BTreeMap<String, u64>>,
    json_out: Option<PathBuf>,
    summary_out: Option<PathBuf>,
}

fn parse_args() -> Args {
    let mut it = env::args().skip(1);
    let (mut vectors, mut runner_json, mut leaves, mut base) = (None, None, None, None);
    let (mut changes, mut controls, mut expected, mut json_out, mut summary_out) = (vec![], vec![], None, None, None);
    while let Some(a) = it.next() {
        let mut val = || it.next().unwrap_or_else(|| die(format!("{a} needs a value")));
        match a.as_str() {
            "--vectors" => vectors = Some(PathBuf::from(val())),
            "--runner-json" => runner_json = Some(PathBuf::from(val())),
            "--leaves" => leaves = Some(val().split_whitespace().map(String::from).collect::<Vec<_>>()),
            "--base" => base = Some(PathBuf::from(val())),
            "--change" => {
                let v = val();
                let (l, d) = v.split_once('=').unwrap_or_else(|| die(format!("--change {v}: want <label>=<dir>")));
                changes.push((l.to_string(), PathBuf::from(d)));
            }
            "--control" => controls.push(val()),
            "--expected" => {
                let mut m = BTreeMap::new();
                for t in val().split_whitespace() {
                    let (l, n) = t.split_once('=').unwrap_or_else(|| die(format!("--expected {t}: want <leaf>=<n>")));
                    m.insert(l.to_string(), n.parse().unwrap_or_else(|_| die(format!("--expected {t}: bad count"))));
                }
                expected = Some(m);
            }
            "--json" => json_out = Some(PathBuf::from(val())),
            "--summary" => summary_out = Some(PathBuf::from(val())),
            _ => die(format!("unknown argument {a}")),
        }
    }
    let args = Args {
        vectors: vectors.unwrap_or_else(|| die("--vectors is required".into())),
        runner_json: runner_json.unwrap_or_else(|| die("--runner-json is required".into())),
        leaves: leaves.unwrap_or_else(|| die("--leaves is required".into())),
        base: base.unwrap_or_else(|| die("--base is required".into())),
        changes,
        controls,
        expected,
        json_out,
        summary_out,
    };
    for c in &args.controls {
        if !args.changes.iter().any(|(l, _)| l == c) {
            die(format!("--control {c} names no --change label"));
        }
    }
    if let Some(e) = &args.expected {
        for l in e.keys() {
            if !args.leaves.contains(l) {
                die(format!("--expected names leaf {l}, which is not in --leaves"));
            }
        }
    }
    args
}

/// The dimensions SANTA's orchestrator records as red for one verdict (tools/conform/src/main.rs, `tally`):
/// empty = the entry passes.
fn red_dims(g: &Value) -> Vec<String> {
    let s = |k: &str| g[k].as_str().unwrap_or("");
    let mut red: Vec<String> = Vec::new();
    let mut dim = |name: &str, ok: bool| {
        if !ok {
            red.push(name.to_string())
        }
    };
    match s("kind") {
        "panicked" => dim("panicked", false),
        "coverage" => dim(g["tag"].as_str().unwrap_or("coverage"), false),
        "reject" => dim("reject", s("verdict") == "nice"),
        "roundtrip" => dim("roundtrip", s("verdict") == "nice"),
        "transaction" => {
            dim("valid", s("valid") == "nice");
            dim("cost", s("cost") == "n/a" || s("cost") == "nice");
        }
        "block" => {
            dim("valid", s("valid") == "nice");
            dim("post_digest", s("post_digest") == "n/a" || s("post_digest") == "nice");
            dim("cost", s("cost") == "n/a" || s("cost") == "nice");
        }
        "chain" => dim("value", s("value") == "nice"),
        "authds_prove" => {
            dim("proof", s("proof") == "nice");
            dim("digest", s("digest") == "nice");
        }
        "authds_verify" => {
            dim("accepted", s("accepted") == "nice");
            dim("results", s("results") == "n/a" || s("results") == "nice");
            dim("digest", s("digest") == "n/a" || s("digest") == "nice");
        }
        "nipopow_interlinks" => dim("interlinks", s("interlinks") == "nice"),
        "nipopow_prove" => dim("proof", s("proof") == "nice"),
        _ => {
            dim("value", s("value") == "nice");
            dim("cost", s("cost") == "n/a" || s("cost") == "nice");
        }
    }
    red
}

/// One vector entry graded: SANTA's verdict object, the red dimensions, and the runner's actual.
struct Entry {
    grade: Value,
    red: Vec<String>,
    actual: Value,
}

impl Entry {
    fn verdict(&self) -> String {
        if self.red.is_empty() { "nice".into() } else { self.red.join("+") }
    }
    /// The actual's outcome tag: "ok" (error null), or the error tag (errored, panicked, not-implemented), or
    /// "absent" when the runner wrote nothing for the entry.
    fn outcome(&self) -> String {
        if self.actual.is_null() {
            return "absent".into();
        }
        match self.actual.get("error") {
            None | Some(Value::Null) => "ok".into(),
            Some(Value::String(t)) => t.clone(),
            Some(v) => v.to_string(),
        }
    }
    fn to_json(&self) -> Value {
        json!({"verdict": self.verdict(), "outcome": self.outcome(), "grade": self.grade, "actual": self.actual})
    }
}

type Key = (String, String, String); // (leaf, vector file stem, entry name)

#[derive(Default)]
struct Leaf {
    vector_files: u64,
    actual_files: u64,
    missing_actual_files: Vec<String>,
    extra_actual_files: Vec<String>,
    entries: u64,
    absent_entries: u64,
    failing: u64,
    red_dims: u64,
}

struct Graded {
    entries: BTreeMap<Key, Entry>,
    leaves: BTreeMap<String, Leaf>,
}

fn json_files(dir: &Path) -> Vec<String> {
    let mut v: Vec<String> = fs::read_dir(dir)
        .map(|rd| {
            rd.flatten()
                .map(|e| e.path())
                .filter(|p| p.is_file() && p.extension().and_then(|x| x.to_str()) == Some("json"))
                .map(|p| p.file_stem().unwrap().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

/// Grade every entry of every vector file under the given leaves, as SANTA's orchestrator does: dispatch on the
/// vector's `schema`, an absent actuals file reads as `{}` and an absent entry as null (both graded, as coal).
fn grade_label(dir: &Path, vectors: &Path, leaves: &[String], claims_cost: bool) -> Graded {
    let mut g = Graded { entries: BTreeMap::new(), leaves: BTreeMap::new() };
    for leaf in leaves {
        let vdir = vectors.join(leaf);
        let adir = dir.join("actuals").join(leaf);
        let ops = json_files(&vdir);
        if ops.is_empty() {
            die(format!("no vector files under {}", vdir.display()));
        }
        let acts = json_files(&adir);
        let lc = g.leaves.entry(leaf.clone()).or_default();
        lc.vector_files = ops.len() as u64;
        lc.extra_actual_files = acts.iter().filter(|a| !ops.contains(a)).cloned().collect();
        for op in &ops {
            let vec = read_json(&vdir.join(format!("{op}.json")));
            let apath = adir.join(format!("{op}.json"));
            let act = if apath.is_file() {
                lc.actual_files += 1;
                read_json(&apath)
            } else {
                lc.missing_actual_files.push(op.clone());
                json!({})
            };
            let schema = vec["schema"].as_str().unwrap_or("");
            let entries = vec["entries"].as_array().unwrap_or_else(|| die(format!("{leaf}/{op}: no entries")));
            for e in entries {
                let name = e["name"].as_str().unwrap_or_else(|| die(format!("{leaf}/{op}: entry without name")));
                let actual = act.get(name).cloned().unwrap_or(Value::Null);
                let verdict = if schema.starts_with("santa-wire/") {
                    grade_wire(&actual, e)
                } else if schema.starts_with("santa-transaction/") {
                    grade_transaction(&actual, &e["expected"])
                } else if schema.starts_with("santa-block/") {
                    grade_block(&actual, &e["expected"])
                } else if schema.starts_with("santa-chain/") {
                    grade_chain(&actual, e)
                } else if schema.starts_with("santa-authds/") {
                    grade_authds(&actual, e)
                } else if schema.starts_with("santa-nipopow/") {
                    grade_nipopow(&actual, e, &vec["chain"])
                } else {
                    grade(&actual, &e["expected"], claims_cost)
                };
                let red = red_dims(&verdict);
                lc.entries += 1;
                lc.absent_entries += actual.is_null() as u64;
                lc.failing += !red.is_empty() as u64;
                lc.red_dims += red.len() as u64;
                let key = (leaf.clone(), op.clone(), name.to_string());
                if g.entries.insert(key, Entry { grade: verdict, red, actual }).is_some() {
                    die(format!("{leaf}/{op}: duplicate entry name {name}"));
                }
            }
        }
    }
    g
}

/// One change: its label, its manifest, and (when it was built) its grades and its diff against the base.
type Row = (String, Value, Option<(Graded, Diff)>);

#[derive(Default)]
struct Diff {
    fixed: Vec<Key>,
    regressed: Vec<Key>,
    verdict_changed: Vec<Key>,
    output_changed: Vec<Key>,
}

fn diff(base: &Graded, change: &Graded) -> Diff {
    let mut d = Diff::default();
    for (k, b) in &base.entries {
        let c = &change.entries[k]; // same vectors, same keys
        match (b.red.is_empty(), c.red.is_empty()) {
            (false, true) => d.fixed.push(k.clone()),
            (true, false) => d.regressed.push(k.clone()),
            _ if !structural_equal(&b.grade, &c.grade) => d.verdict_changed.push(k.clone()),
            _ if !structural_equal(&b.actual, &c.actual) => d.output_changed.push(k.clone()),
            _ => {}
        }
    }
    d
}

fn manifest(dir: &Path) -> Value {
    let p = dir.join("manifest.json");
    if p.is_file() { read_json(&p) } else { Value::Null }
}

fn status(m: &Value) -> String {
    m.get("status").and_then(Value::as_str).unwrap_or("ok").to_string()
}

fn short(v: &Value) -> String {
    v.as_str().map(|s| s.chars().take(12).collect()).unwrap_or_else(|| "-".into())
}

fn trunc(s: &str, n: usize) -> String {
    if s.chars().count() <= n { s.to_string() } else { format!("{}…", s.chars().take(n).collect::<String>()) }
}

fn md_escape(s: &str) -> String {
    s.replace('|', "\\|").replace('\n', " ")
}

const LIST_CAP: usize = 200;

fn main() -> ExitCode {
    let a = parse_args();
    let runner = read_json(&a.runner_json);
    // SANTA's orchestrator reads `cost` from runner.json, default true (tools/conform/src/main.rs, `discover`).
    let claims_cost = runner.get("cost").and_then(Value::as_bool).unwrap_or(true);
    let mut md = String::new();
    let mut failures: Vec<String> = Vec::new();
    let mut out = json!({
        "schema": "sigma-rust-vector-diff/1",
        "comparator": "santa-check (SANTA tools/santa-check), dispatch and red rule of tools/conform",
        "runner": {"name": runner["name"], "cost": claims_cost},
        "leaves": a.leaves,
    });

    let base_m = manifest(&a.base);
    if status(&base_m) != "ok" {
        let msg = format!("base was not built (status {})", status(&base_m));
        let _ = writeln!(md, "## sigma-rust vector diff\n\n**{msg}**: nothing graded.");
        finish(&a, &md, out, &[msg])
    }
    let base = grade_label(&a.base, &a.vectors, &a.leaves, claims_cost);

    let _ = writeln!(md, "## sigma-rust vector diff\n");
    let _ = writeln!(
        md,
        "Base: sigma-rust `{}`. Graded with SANTA's comparator (`tools/santa-check`; runner `{}`, cost claimed: {}).\n",
        base_m["sigma_rust_head"].as_str().unwrap_or("-"),
        runner["name"].as_str().unwrap_or("-"),
        claims_cost
    );

    // Base per leaf, with the expected failing counts when given.
    let _ = writeln!(md, "### Base: failing entries per leaf\n");
    let _ = writeln!(md, "| leaf | vector files | actuals files | entries | failing | red dimensions | expected failing | |");
    let _ = writeln!(md, "|---|---:|---:|---:|---:|---:|---:|---|");
    let mut base_json = serde_json::Map::new();
    for (leaf, c) in &base.leaves {
        let exp = a.expected.as_ref().and_then(|e| e.get(leaf)).copied();
        let mark = match exp {
            Some(n) if n == c.failing => "match",
            Some(_) => "**differs**",
            None => "",
        };
        if let Some(n) = exp {
            if n != c.failing {
                failures.push(format!("base {leaf}: {} failing, expected {n}", c.failing));
            }
        }
        if !c.missing_actual_files.is_empty() {
            failures.push(format!("base {leaf}: {} actuals files missing", c.missing_actual_files.len()));
        }
        let _ = writeln!(
            md,
            "| {leaf} | {} | {} | {} | {} | {} | {} | {mark} |",
            c.vector_files,
            c.actual_files,
            c.entries,
            c.failing,
            c.red_dims,
            exp.map(|n| n.to_string()).unwrap_or_else(|| "-".into())
        );
        let failing: Vec<Value> = base
            .entries
            .iter()
            .filter(|(k, e)| &k.0 == leaf && !e.red.is_empty())
            .map(|(k, e)| json!({"file": k.1, "entry": k.2, "verdict": e.verdict(), "outcome": e.outcome()}))
            .collect();
        base_json.insert(
            leaf.clone(),
            json!({"vector_files": c.vector_files, "actual_files": c.actual_files,
                   "missing_actual_files": c.missing_actual_files, "extra_actual_files": c.extra_actual_files,
                   "entries": c.entries, "absent_entries": c.absent_entries, "failing": c.failing,
                   "red_dims": c.red_dims, "expected_failing": exp, "failing_entries": failing}),
        );
    }
    let tot = |f: fn(&Leaf) -> u64| base.leaves.values().map(f).sum::<u64>();
    let _ = writeln!(
        md,
        "| total | {} | {} | {} | {} | {} | {} | |\n",
        tot(|c| c.vector_files),
        tot(|c| c.actual_files),
        tot(|c| c.entries),
        tot(|c| c.failing),
        tot(|c| c.red_dims),
        a.expected.as_ref().map(|e| e.values().sum::<u64>().to_string()).unwrap_or_else(|| "-".into())
    );
    out["base"] = json!({"manifest": base_m, "leaves": base_json});

    // Changes.
    let mut graded: Vec<Row> = Vec::new();
    for (label, dir) in &a.changes {
        let m = manifest(dir);
        if status(&m) != "ok" {
            graded.push((label.clone(), m, None));
            continue;
        }
        let g = grade_label(dir, &a.vectors, &a.leaves, claims_cost);
        for (leaf, c) in &g.leaves {
            if !c.missing_actual_files.is_empty() {
                let _ = writeln!(md, "> {label} {leaf}: {} actuals files missing (graded as coal, as SANTA does)\n", c.missing_actual_files.len());
            }
        }
        let d = diff(&base, &g);
        graded.push((label.clone(), m, Some((g, d))));
    }

    let _ = writeln!(md, "### Changes against the base\n");
    let _ = writeln!(md, "| label | change | sigma-rust HEAD | change head | fixed | regressed | verdict changed, same pass/fail | output changed, same verdict |");
    let _ = writeln!(md, "|---|---|---|---|---:|---:|---:|---:|");
    for (label, m, r) in &graded {
        let ch = m["change"].as_str().unwrap_or("-");
        match r {
            None => {
                let _ = writeln!(md, "| {label} | {ch} | - | {} | not built: {} | | | |", short(&m["change_head"]), status(m));
            }
            Some((_, d)) => {
                let _ = writeln!(
                    md,
                    "| {label} | {ch} | {} | {} | {} | {} | {} | {} |",
                    short(&m["sigma_rust_head"]),
                    short(&m["change_head"]),
                    d.fixed.len(),
                    d.regressed.len(),
                    d.verdict_changed.len(),
                    d.output_changed.len()
                );
            }
        }
    }
    let _ = writeln!(md);

    let mut changes_json = serde_json::Map::new();
    for (label, m, r) in &graded {
        let Some((g, d)) = r else {
            changes_json.insert(label.clone(), json!({"manifest": m, "status": status(m)}));
            continue;
        };
        let item = |k: &Key| {
            json!({"leaf": k.0, "file": k.1, "entry": k.2,
                   "base": base.entries[k].to_json(), "change": g.entries[k].to_json()})
        };
        let mut per_file: BTreeMap<(String, String), [usize; 4]> = BTreeMap::new();
        for (i, list) in [&d.fixed, &d.regressed, &d.verdict_changed, &d.output_changed].iter().enumerate() {
            for k in list.iter() {
                per_file.entry((k.0.clone(), k.1.clone())).or_default()[i] += 1;
            }
        }
        let per_leaf: BTreeMap<String, Value> = a
            .leaves
            .iter()
            .map(|l| {
                let n = |v: &Vec<Key>| v.iter().filter(|k| &k.0 == l).count();
                (l.clone(), json!({"fixed": n(&d.fixed), "regressed": n(&d.regressed),
                    "verdict_changed": n(&d.verdict_changed), "output_changed": n(&d.output_changed),
                    "failing": g.leaves[l].failing}))
            })
            .collect();
        changes_json.insert(
            label.clone(),
            json!({"manifest": m, "status": "ok", "per_leaf": per_leaf,
                   "counts": {"fixed": d.fixed.len(), "regressed": d.regressed.len(),
                              "verdict_changed": d.verdict_changed.len(), "output_changed": d.output_changed.len()},
                   "fixed": d.fixed.iter().map(item).collect::<Vec<_>>(),
                   "regressed": d.regressed.iter().map(item).collect::<Vec<_>>(),
                   "verdict_changed": d.verdict_changed.iter().map(item).collect::<Vec<_>>(),
                   "output_changed": d.output_changed.iter().map(item).collect::<Vec<_>>()}),
        );
        if per_file.is_empty() {
            let _ = writeln!(md, "#### {label}: no entry changed\n");
            continue;
        }
        let _ = writeln!(md, "#### {label} ({}), by leaf and vector file\n", m["change"].as_str().unwrap_or("-"));
        let _ = writeln!(md, "| leaf | vector file | fixed | regressed | verdict changed | output changed |");
        let _ = writeln!(md, "|---|---|---:|---:|---:|---:|");
        for ((leaf, op), n) in &per_file {
            let _ = writeln!(md, "| {leaf} | {op} | {} | {} | {} | {} |", n[0], n[1], n[2], n[3]);
        }
        let _ = writeln!(md);
        for (title, list) in [
            ("fixed", &d.fixed),
            ("regressed", &d.regressed),
            ("verdict changed, same pass/fail", &d.verdict_changed),
            ("output changed, same verdict", &d.output_changed),
        ] {
            if list.is_empty() {
                continue;
            }
            let _ = writeln!(md, "<details><summary>{label}: {title} ({})</summary>\n", list.len());
            let _ = writeln!(md, "| leaf | vector file | entry | base verdict (outcome) | change verdict (outcome) |");
            let _ = writeln!(md, "|---|---|---|---|---|");
            for k in list.iter().take(LIST_CAP) {
                let (b, c) = (&base.entries[k], &g.entries[k]);
                let _ = writeln!(
                    md,
                    "| {} | {} | {} | {} ({}) | {} ({}) |",
                    k.0,
                    k.1,
                    md_escape(&trunc(&k.2, 90)),
                    b.verdict(),
                    b.outcome(),
                    c.verdict(),
                    c.outcome()
                );
            }
            if list.len() > LIST_CAP {
                let _ = writeln!(md, "\n{} more in the JSON report.", list.len() - LIST_CAP);
            }
            let _ = writeln!(md, "\n</details>\n");
        }
    }
    out["changes"] = Value::Object(changes_json);

    // Controls.
    let mut controls_json = Vec::new();
    for c in &a.controls {
        let (_, m, r) = graded.iter().find(|(l, _, _)| l == c).unwrap();
        let (ok, text) = match r {
            None => (false, format!("{c}: not built (status {})", status(m))),
            Some((_, d)) => (
                d.fixed.is_empty() && d.regressed.is_empty(),
                format!(
                    "{c}: fixed {}, regressed {} (verdict changed {}, output changed {})",
                    d.fixed.len(),
                    d.regressed.len(),
                    d.verdict_changed.len(),
                    d.output_changed.len()
                ),
            ),
        };
        if !ok {
            failures.push(format!("control {text}"));
        }
        controls_json.push(json!({"control": c, "pass": ok, "detail": text}));
    }
    out["controls"] = json!(controls_json);
    let _ = writeln!(md, "### Controls\n");
    for c in &controls_json {
        let _ = writeln!(md, "- {}: {}", if c["pass"] == true { "PASS" } else { "**FAIL**" }, c["detail"].as_str().unwrap());
    }
    match &a.expected {
        Some(e) => {
            let bad: Vec<&String> = e.keys().filter(|l| base.leaves[*l].failing != e[*l]).collect();
            let _ = writeln!(
                md,
                "- {}: base failing entries per leaf against the expected counts ({} leaves checked{})",
                if bad.is_empty() { "PASS" } else { "**FAIL**" },
                e.len(),
                if bad.is_empty() {
                    String::new()
                } else {
                    format!("; differ: {}", bad.iter().map(|l| format!("{l} {} vs {}", base.leaves[*l].failing, e[*l])).collect::<Vec<_>>().join(", "))
                }
            );
        }
        None => {
            let _ = writeln!(md, "- base failing counts: no expected counts given, not checked");
        }
    }
    out["expected_failing"] = json!(a.expected);
    finish(&a, &md, out, &failures)
}

fn finish(a: &Args, md: &str, mut out: Value, failures: &[String]) -> ! {
    out["control_failures"] = json!(failures);
    let mut md = md.to_string();
    if !failures.is_empty() {
        let _ = writeln!(md, "\n**Control failures:**\n");
        for f in failures {
            let _ = writeln!(md, "- {f}");
        }
    }
    match &a.summary_out {
        Some(p) => fs::write(p, &md).unwrap_or_else(|e| die(format!("write {}: {e}", p.display()))),
        None => print!("{md}"),
    }
    if let Some(p) = &a.json_out {
        fs::write(p, serde_json::to_string_pretty(&out).unwrap() + "\n")
            .unwrap_or_else(|e| die(format!("write {}: {e}", p.display())));
    }
    for f in failures {
        eprintln!("control failure: {f}");
    }
    std::process::exit(if failures.is_empty() { 0 } else { 1 })
}
