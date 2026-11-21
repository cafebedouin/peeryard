//! Parses each serialized header in the file given as the first argument (lines: `<name> <hex>`) and prints
//! `Header::check_pow` and `AutolykosPowScheme::pow_hit` for it, or the panic and its location.
//! Copied by run.sh into `ergo-chain-types/examples/` of the sigma-rust tree under test.
use ergo_chain_types::autolykos_pow_scheme::AutolykosPowScheme;
use ergo_chain_types::Header;
use sigma_ser::ScorexSerializable;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Mutex;

static LAST_PANIC: Mutex<String> = Mutex::new(String::new());

fn run<T: std::fmt::Display, E: std::fmt::Display>(f: impl FnOnce() -> Result<T, E>) -> String {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(v)) => format!("Ok({v})"),
        Ok(Err(e)) => format!("Err({e})"),
        Err(_) => format!("PANIC({})", LAST_PANIC.lock().unwrap()),
    }
}

fn main() {
    std::panic::set_hook(Box::new(|info| {
        let loc = info.location().map(|l| format!("{}:{}", l.file(), l.line())).unwrap_or_default();
        let msg = info
            .payload()
            .downcast_ref::<String>()
            .cloned()
            .or_else(|| info.payload().downcast_ref::<&str>().map(|s| s.to_string()))
            .unwrap_or_default();
        *LAST_PANIC.lock().unwrap() = format!("{msg} at {loc}");
    }));
    let path = std::env::args().nth(1).expect("usage: zero_index <headers.hex>");
    for line in std::fs::read_to_string(path).unwrap().lines() {
        let (name, hex) = line.split_once(' ').unwrap();
        let bytes: Vec<u8> = (0..hex.len()).step_by(2).map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap()).collect();
        let h = Header::scorex_parse_bytes(&bytes).expect("header parses");
        let check = run(|| h.check_pow());
        let hit = run(|| AutolykosPowScheme::default().pow_hit(&h));
        println!("{name} height={} check_pow={check} pow_hit={hit}", h.height);
    }
}
