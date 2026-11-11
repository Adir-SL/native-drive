import XCTest
@testable import NativeDriveCore

final class SnappyTests: XCTestCase {
    func testMemoryCacheHitUpdatesAndEvictsLeastRecentlyUsed() {
        var cache = ListingMemoryCache(limit: 2)
        cache.store(listing("a", [sampleFile(id: "1", name: "A")]))
        cache.store(listing("b", [sampleFile(id: "2", name: "B")]))
        XCTAssertEqual(cache.listing(for: "a")?.files.map(\.name), ["A"])
        cache.store(listing("c", [sampleFile(id: "3", name: "C")]))
        XCTAssertNil(cache.listing(for: "b"))
        XCTAssertEqual(cache.listing(for: "a")?.key, "a")
        XCTAssertEqual(cache.listing(for: "c")?.key, "c")

        var updated = listing("a", [sampleFile(id: "1", name: "A2")])
        updated.fetchedAt = Date(timeIntervalSince1970: 50)
        cache.store(updated)
        XCTAssertEqual(cache.listing(for: "a")?.files.map(\.name), ["A2"])
        XCTAssertEqual(cache.count, 2)
    }

    func testListingFreshnessAndReconcile() {
        let fresh = CachedListing(key: "myDrive", files: [], nextPageToken: nil, fetchedAt: Date(timeIntervalSince1970: 100))
        XCTAssertFalse(ListingFreshness.isStale(fresh, now: Date(timeIntervalSince1970: 110)))
        XCTAssertTrue(ListingFreshness.isStale(fresh, now: Date(timeIntervalSince1970: 130)))

        let current = [sampleFile(id: "1", name: "A"), sampleFile(id: "2", name: "B")]
        XCTAssertEqual(ListingReconciler.reconcile(current: current, incoming: current), current)
        var renamed = current
        renamed[1] = sampleFile(id: "2", name: "Bee")
        let reconciled = ListingReconciler.reconcile(current: current, incoming: renamed)
        XCTAssertEqual(reconciled.map(\.name), ["A", "Bee"])
        XCTAssertEqual(reconciled[0], current[0])
        let reordered = [current[1], current[0]]
        XCTAssertEqual(ListingReconciler.reconcile(current: current, incoming: reordered).map(\.id), ["2", "1"])
    }

    func testRefreshKeepsTailUntilTheLastPage() {
        let existing = [
            sampleFile(id: "1", name: "B"),
            sampleFile(id: "2", name: "C"),
            sampleFile(id: "9", name: "Old")
        ]
        let page = [sampleFile(id: "1", name: "B2"), sampleFile(id: "3", name: "A", mimeType: DriveMime.folder)]
        let merged = ListingRefresh.mergePage(existing: existing, page: page, key: DriveLocation.myDrive.cacheKey)
        XCTAssertEqual(merged.map(\.id), ["3", "1", "2", "9"])
        XCTAssertEqual(merged.first { $0.id == "1" }?.name, "B2")
        let closed = ListingRefresh.droppingUnseen(files: merged, seen: ["1", "3"], key: DriveLocation.myDrive.cacheKey)
        XCTAssertEqual(closed.map(\.id), ["3", "1"])
    }

    func testMetadataIndexRemembersListingFilesAndEvicts() {
        var index = FileMetadataIndex(limit: 2)
        index.remember([sampleFile(id: "1", name: "A"), sampleFile(id: "2", name: "B")])
        index.remember(sampleFile(id: "3", name: "C"))
        XCTAssertNil(index.file(id: "1"))
        XCTAssertEqual(index.file(id: "2")?.name, "B")
        index.remember(sampleFile(id: "2", name: "Bee"))
        XCTAssertEqual(index.file(id: "2")?.name, "Bee")
        XCTAssertEqual(index.count, 2)
    }

    func testPrefetchSchedulerLimitsPriorityAndCancellation() {
        var scheduler = PrefetchScheduler(limit: 2)
        let first = scheduler.setRelevant([
            PrefetchJob(id: "c", priority: 5),
            PrefetchJob(id: "a", priority: 0),
            PrefetchJob(id: "b", priority: 1)
        ])
        XCTAssertEqual(first.start.map(\.id), ["a", "b"])
        XCTAssertEqual(first.cancel, [])
        XCTAssertEqual(scheduler.queued.map(\.id), ["c"])

        let started = scheduler.finished("a")
        XCTAssertEqual(started.map(\.id), ["c"])
        XCTAssertEqual(scheduler.running.map(\.id), ["b", "c"])

        let replaced = scheduler.setRelevant([PrefetchJob(id: "b", priority: 1), PrefetchJob(id: "d", priority: 0)])
        XCTAssertEqual(replaced.cancel.map(\.id), ["c"])
        XCTAssertEqual(replaced.start.map(\.id), ["d"])
        XCTAssertEqual(Set(scheduler.running.map(\.id)), ["b", "d"])
        XCTAssertTrue(scheduler.queued.isEmpty)

        XCTAssertEqual(scheduler.finished("missing"), [])
    }

    func testPrefetchPlannerChoosesFoldersImagesAndSkipsHeavyOrConstrainedWork() {
        XCTAssertEqual(PrefetchPlanner.hoverDelayNanoseconds, 150_000_000)
        XCTAssertFalse(PrefetchPlanner.allowsNetworkPrefetch(isConstrained: true))
        let files = [
            sampleFile(id: "f1", name: "A", mimeType: DriveMime.folder),
            sampleFile(id: "f2", name: "B", mimeType: DriveMime.folder),
            sampleFile(id: "p", name: "c.jpg", mimeType: "image/jpeg"),
            sampleFile(id: "f3", name: "C", mimeType: DriveMime.folder),
            sampleFile(id: "f4", name: "D", mimeType: DriveMime.folder),
            sampleFile(id: "f5", name: "E", mimeType: DriveMime.folder)
        ]
        XCTAssertEqual(PrefetchPlanner.subfolders(in: files).map(\.id), ["f1", "f2", "f3", "f4"])

        let images = [
            image("a", size: 10),
            image("b", size: 10),
            image("c", size: 10),
            image("d", size: 10),
            image("e", size: PrefetchPlanner.maxPrefetchBytes + 1)
        ]
        XCTAssertEqual(
            PrefetchPlanner.imageIDs(in: images, currentID: "c", direction: 1, isConstrained: false),
            ["b", "d"]
        )
        XCTAssertEqual(
            PrefetchPlanner.imageIDs(in: images, currentID: "c", direction: -1, isConstrained: false),
            ["d", "b", "a"]
        )
        XCTAssertEqual(
            PrefetchPlanner.imageIDs(in: images, currentID: "c", direction: 0, isConstrained: false),
            ["b", "d"]
        )
        XCTAssertTrue(PrefetchPlanner.imageIDs(in: images, currentID: "c", direction: 1, isConstrained: true).isEmpty)
        XCTAssertEqual(ThumbnailPlan.proxyEdge(forPixelLength: 700), 1024)
        XCTAssertEqual(ThumbnailPlan.proxyEdge(forPixelLength: 4000), 2048)
        XCTAssertEqual(DriveQueryBuilder.clampedPageSize(5_000), 1_000)
        XCTAssertEqual(DriveQueryBuilder.defaultPageSize, 1_000)
    }

    private func image(_ id: String, size: Int64) -> DriveFile {
        DriveFile(id: id, name: "\(id).jpg", mimeType: "image/jpeg", size: size)
    }
}
