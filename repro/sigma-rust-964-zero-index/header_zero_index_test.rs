
#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod zero_index_pow_tests {
    use crate::autolykos_pow_scheme::AutolykosPowScheme;
    use crate::header::Header;
    use sigma_ser::ScorexSerializable;

    /// Mainnet header 1,914,880 with nBits set to difficulty 4 and nonce 45,878,571: one of its 32 table indexes
    /// is 0, and its hit is under the difficulty-4 target. Hit and verdict from the ergo v6.0.8 jar
    /// (`AutolykosPowScheme(32, 26)`: `hitForVersion2`, `validate` succeeds).
    const HEADER: [&str; 5] = [
        "0450c97c3830e0e1cff0ad8ce79490a181396755629de212b37877e3dadb7c1e786584ac5160c3cd4bf41ad7f1077877",
        "b713ece9b3ca4b0d37cc09f743cc8b4afaafe4e704c052d85d24ce662113356c1187d4b612cb54cc524ef6d57d6b6acc",
        "9a5973b3154113f1f4e041b6ea1983effca522031c663a9b99eae93c58f5169e20199aacbaf09c34f6f1cc8461870b92",
        "e91c303af68e077966cf8845b340b33f9f6af6bb4d350ae70104000080f074000000000274e729bb6615cbda94d9d176",
        "a2f1525068f12b330e38bbbf387232797dfd891f0000000002bc0d2b",
    ];
    const HIT: &str = "28826635331816278422055773760399954877389389236516583930937018919255638089733";

    #[test]
    fn check_pow_with_a_zero_index_matches_the_reference() {
        let h = Header::scorex_parse_bytes(&base16::decode(&HEADER.concat()).unwrap()).unwrap();
        assert_eq!(AutolykosPowScheme::default().pow_hit(&h).unwrap().to_string(), HIT);
        assert!(h.check_pow().unwrap());
    }
}
