package org.ergoplatform.nodeView.history.extra

import akka.actor.Props
import akka.testkit.TestProbe
import org.ergoplatform.nodeView.history.extra.ExtraIndexer.ReceivableMessages.Index

import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.Condition
import scala.concurrent.duration.DurationInt

// peeryard bench (bench/indexer): the extra indexer's rebuild rate from an empty index over a generated chain.
// Copied into an ergo tree next to ExtraIndexerSpecification and run with
//   BENCH_BLOCKS=<n> sbt "testOnly *ExtraIndexerRebuildRateSpec -- -z PEERYARD-BENCH"
// It reuses the spec's chain generator and test actor, with the production write settings instead of the
// fixture's: saveLimit = extraCacheSize (1000) * 20, segmentThreshold = 512, storage-rent index off (the default).
// Only the indexing phase is timed (Index() sent -> indexer caught up and its buffer written).
// Chains longer than ~100 blocks need the generator to stop minting a token in every block (the carried tokens pass
// the 4096-byte box limit); .github/workflows/indexer-bench.yml makes that one-line edit to ChainGenerator.scala.
class ExtraIndexerRebuildBenchActor(test: ExtraIndexerSpecification) extends ExtraIndexerTestActor(test, false) {
  override protected def saveLimit: Int = 20000
  override protected implicit val segmentThreshold: Int = 512
}

class ExtraIndexerRebuildRateSpec extends ExtraIndexerSpecification {

  override def awaitCondition(condition: Condition): Unit = {
    lock.lock()
    try {
      if (!condition.await(60, TimeUnit.MINUTES)) throw new AssertionError("bench: indexer did not catch up in 60 min")
    } finally lock.unlock()
  }

  property("PEERYARD-BENCH rebuild rate") {
    val blocks = sys.env.getOrElse("BENCH_BLOCKS", "200").toInt
    val bench = system.actorOf(Props.create(classOf[ExtraIndexerRebuildBenchActor], this))
    val probe = TestProbe()(system)
    val g0 = System.nanoTime()
    probe.send(bench, CreateDB(blocks))
    probe.send(bench, GetLoadedState())
    probe.expectMsgType[IndexerState](60.minutes)
    val g1 = System.nanoTime()
    bench ! Index()
    awaitCondition(done)
    val i1 = System.nanoTime()
    val state = IndexerState.fromHistory(_history)
    state.indexedHeight shouldBe blocks
    val indexS = (i1 - g1) / 1e9
    println(f"PEERYARD-BENCH schema=${ExtraIndexer.NewestVersion} blocks=${state.indexedHeight} " +
      f"txs=${state.globalTxIndex} boxes=${state.globalBoxIndex} gen_s=${(g1 - g0) / 1e9}%.2f index_s=$indexS%.3f " +
      f"blocks_per_min=${state.indexedHeight * 60 / indexS}%.0f txs_per_min=${state.globalTxIndex * 60 / indexS}%.0f " +
      f"boxes_per_min=${state.globalBoxIndex * 60 / indexS}%.0f")
  }
}
