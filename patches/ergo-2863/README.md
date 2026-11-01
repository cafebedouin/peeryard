# ergoplatform/ergo#2863: ForkResolutionSpec as it was before #2809

`forkres-pre2809.patch` replaces `src/it/scala/org/ergoplatform/it/ForkResolutionSpec.scala` at `v6.0.11`
(`4837b0141`) and at the PR head with the file at `05c7d254c^` (the parent of #2809's merge): `commonChainLength = 16`,
`forkLength = 5`. The spec preimage is the same on both arms. For the `ref-specs` workflow, both arms:

    gh workflow run ref-specs.yml -f repo=https://github.com/cafebedouin/ergo -f label=v2-continuation-fork \
      -f arms='base:4837b01419d08b279c9a4fd920b4260dc7873b15:patches/ergo-2863/forkres-pre2809.patch head:ead40a57a0f035036cc39d75492b335186361542:patches/ergo-2863/forkres-pre2809.patch' \
      -f it_spec=org.ergoplatform.it.ForkResolutionSpec -f it_minutes=25 -f repeats=3

It reads whether a follower whose own fork is more than 16 headers long, with its tip at height 128 or lower,
switches to the heavier chain (#2785).
