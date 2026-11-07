package org.boardgamescafe.dicetower

import org.junit.Assert.*
import org.junit.Test

class ReportedRollFilterTest {
    private fun face(value: Int,x: Double=.2,confidence: Double=.9)=Face(value,confidence,Box(x,.2,.1,.1))
    @Test fun duplicatesIgnoreOrderConfidenceAndSmallJitter() {
        val filter=ReportedRollFilter();assertNull(filter.duplicateEventId(listOf(face(3))))
        filter.record(listOf(face(3),face(4,.6)),"first")
        assertEquals("first",filter.duplicateEventId(listOf(face(4,.605,.8),face(3,.205))))
    }
    @Test fun movedDiceChangedValuesAndCountsAreNewReadings() {
        val filter=ReportedRollFilter();filter.record(listOf(face(3)),"first")
        assertNull(filter.duplicateEventId(listOf(face(3,.22))))
        assertNull(filter.duplicateEventId(listOf(face(4))))
        assertNull(filter.duplicateEventId(emptyList()))
    }
    @Test fun discardedReadingsDoNotMoveReferenceAndNewSharingStartsFresh() {
        val filter=ReportedRollFilter();filter.record(listOf(face(3)),"first")
        assertEquals("first",filter.duplicateEventId(listOf(face(3,.206))))
        assertNull(filter.duplicateEventId(listOf(face(3,.212))))
        filter.record(listOf(face(3,.212)),"second")
        assertEquals("second",filter.duplicateEventId(listOf(face(3,.212))))
        filter.clear();assertNull(filter.duplicateEventId(listOf(face(3,.212))))
    }
    @Test fun emptyTrayOnlyMatchesReportedEmptyTray() {
        val filter=ReportedRollFilter();assertNull(filter.duplicateEventId(emptyList()))
        filter.record(emptyList(),"empty");assertEquals("empty",filter.duplicateEventId(emptyList()))
        assertNull(filter.duplicateEventId(listOf(face(1))))
    }
}
