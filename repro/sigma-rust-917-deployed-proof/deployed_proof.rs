//! Runs a NiPoPoW proof served by a deployed node through the verifier (public API only).
//! NIPOPOW_PROOF_BIN = path to the serialized proof.
use ergo_nipopow::{NipopowProof, NipopowVerifier};
use sigma_ser::ScorexSerializable;

#[test]
fn deployed_proof() {
    let path = std::env::var("NIPOPOW_PROOF_BIN").expect("set NIPOPOW_PROOF_BIN");
    let bytes = std::fs::read(&path).expect("read proof");
    let proof = match NipopowProof::scorex_parse_bytes(&bytes) {
        Ok(p) => p,
        Err(e) => {
            println!("RESULT parse=ERR {:?}", e);
            return;
        }
    };
    println!(
        "RESULT parse=OK m={} k={} prefix={} suffix_tail={}",
        proof.m,
        proof.k,
        proof.prefix.len(),
        proof.suffix_tail.len()
    );
    let mut checked = 0usize;
    let mut failing = Vec::new();
    for ph in proof.prefix.iter().chain(std::iter::once(&proof.suffix_head)) {
        checked += 1;
        if !ph.check_interlinks_proof() {
            failing.push(ph.header.height);
        }
    }
    println!("RESULT interlink_checks={} failing={}", checked, failing.len());
    for h in &failing {
        println!("RESULT failing_height={} mod1024={}", h, h % 1024);
    }
    let genesis = proof.prefix[0].header.id;
    let mut verifier = NipopowVerifier::new(genesis);
    let processed = verifier.process(proof);
    println!(
        "RESULT process={:?} best_proof_kept={}",
        processed,
        verifier.best_proof().is_some()
    );
}
