//! For a commit that has `NipopowProof::validate` (PR #917): prints which validation step rejects the proof.
//! NIPOPOW_PROOF_BIN = path to the serialized proof.
use ergo_nipopow::NipopowProof;
use sigma_ser::ScorexSerializable;

#[test]
fn deployed_proof_validate() {
    let path = std::env::var("NIPOPOW_PROOF_BIN").expect("set NIPOPOW_PROOF_BIN");
    let bytes = std::fs::read(&path).expect("read proof");
    match NipopowProof::scorex_parse_bytes(&bytes) {
        Ok(proof) => println!("RESULT validate={:?}", proof.validate()),
        Err(e) => println!("RESULT parse=ERR {:?}", e),
    }
}
