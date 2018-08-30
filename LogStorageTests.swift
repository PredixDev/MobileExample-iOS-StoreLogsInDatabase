//
//  LogStorageTests.swift
//  PredixMobileReferenceApp
//
//  Created by Johns, Andy (GE Corporate) on 2/22/16.
//  Copyright © 2016 GE. All rights reserved.
//

import XCTest
import PredixMobileSDK
@testable import PredixMobileiOS

class LogStorageTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // Ensure disk logs are clear before testings
        _ = try? FileManager.default.removeItem(at: LogStorage().logLocation as URL)
    }

    override func tearDown() {

        // ensure no services are registered after testing
        ServiceRouter.sharedInstance.unregisterService(MockDBService.self)
        ServiceRouter.sharedInstance.unregisterService(MockCDBService.self)

        // Put teardown code here. This method is called after the invocation of each test method in the class.
        super.tearDown()
    }

    func testLogStorageInit() {
        let logStorage = LogStorage()

        // ensure every log level is being written to the log system
        Logger.shared.loggerLevel = .trace

        // now logs should be going to the storage array

        let testString = "test log"

        Logger.info(testString)

        // Wait briefly, logs are written asynchronously.
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + 0.1) {
            group.leave()
        }
        group.wait()

        if let lastEntry = logStorage.logStore.last {
            if let logEntry = lastEntry[LogEntryKeys.LogEntry] as? String {
                XCTAssertTrue(logEntry.hasSuffix(testString), "Log entry did not match expected value")
            } else {
               XCTFail("Log dictionary did not contain a string for key: \(LogEntryKeys.LogEntry) : lastEntry[LogEntryKeys.LogEntry]")
            }
        } else {
            XCTFail("Log store did not contain any entries after log entry was made.")
        }
    }

    func testLogArrayToJSONInvalidJSON() {
        let logStorage = LogStorage()

        // create an array that cannot be JSON serialized
        let testLogArrayToFail: [[String : Any]] = [["foo": Date()], ["foo": Date()]]

        let result = logStorage.logArrayToJSON(testLogArrayToFail)

        XCTAssertNil(result, "result of logArrayToJSON was expected to be nil")

    }

    func testLogArrayToJSON() {
        let logStorage = LogStorage()
        let testString = "test log"
        let dateString = logStorage.logDataFormatter.string(from: Date())

        // create an array to serialize
        let testLogArray: [[String : Any]] = [[LogEntryKeys.Date: dateString, LogEntryKeys.LogEntry: testString]]

        let result = logStorage.logArrayToJSON(testLogArray)

        XCTAssertNotNil(result, "result of logArrayToJSON was not expected to be nil")

        let deserializedData = try? JSONSerialization.jsonObject(with: result!, options: JSONSerialization.ReadingOptions(rawValue: 0))

        XCTAssertNotNil(deserializedData, "result of JSONObjectWithData was not expected to be nil")

        if let documentDictionary = deserializedData as? [String : Any] {
            let logs = documentDictionary[LogDocumentKeys.Logs] as? [[String : Any]]
            let deviceId = documentDictionary[LogDocumentKeys.DeviceId] as? String
            let docType = documentDictionary[LogDocumentKeys.DocumentType] as? String

            XCTAssertEqual(deviceId, UIDevice.current.identifierForVendor?.uuidString, "Device Id not as expected")
            XCTAssertEqual(docType, logStorage.LogDocumentType, "Document Type not as expected")
            XCTAssertNotNil(logs, "Log array was not in data")
            XCTAssertEqual(logs?.count, 1, "Count of decoded log array was not as expected")

            let logItem = (logs?.first)! as [String : Any]
            let logEntry = logItem[LogEntryKeys.LogEntry] as? String

            XCTAssertEqual(testString, logEntry, "Log entry did not match expected value")

        } else {
            XCTFail("result of JSONObjectWithData was not expected data type: \(String(describing: deserializedData))")
        }
    }

    func testPersistLogsToDisk() {
        let logStorage = LogStorage()

        XCTAssertFalse(logStorage.hasLogsOnDisk(), "Logs found on disk when not expected")

        // ensure every log level is being written to the log system
        Logger.shared.loggerLevel = .trace

        // now logs should be going to the storeage array

        let testString = "test log"

        Logger.info(testString)

        logStorage.persistLogToDisk()

        XCTAssertTrue(logStorage.hasLogsOnDisk(), "Logs not found on disk when expected")

    }

    func testPersistLogsToDatabase() {
        let logStorage = LogStorage()

        // register our mock database service
        ServiceRouter.sharedInstance.registerService(MockCDBService.self)

        // for this test we should succeed
        MockCDBService.serviceShouldReturnFailure = false
        MockCDBService.expectation = self.expectation(description: "database service called expectation")

        // ensure every log level is being written to the log system
        Logger.shared.loggerLevel = .trace

        let testString = "test log"

        Logger.info(testString)

        let logData = logStorage.logArrayToJSON(logStorage.logStore)!

        let expectation = self.expectation(description: "On Complete expectation")

        logStorage.persistLogToDatabase(logData) { (success: Bool) -> Void in
            XCTAssertTrue(success, "persistLogToDatabase onComplete returned false success")
            expectation.fulfill()
        }

        self.waitForExpectations(timeout: 10, handler: nil)
    }

    func testPersistLogsToDatabaseWithFailure() {
        let logStorage = LogStorage()

        // register our mock database service
        ServiceRouter.sharedInstance.registerService(MockCDBService.self)

        // for this test we should fail
        MockCDBService.serviceShouldReturnFailure = true
        MockCDBService.expectation = self.expectation(description: "database service called expectation")

        // ensure every log level is being written to the log system
        Logger.shared.loggerLevel = .trace

        let testString = "test log"

        Logger.info(testString)

        let logData = logStorage.logArrayToJSON(logStorage.logStore)!

        let expectation = self.expectation(description: "On Complete expectation")

        logStorage.persistLogToDatabase(logData) { (success: Bool) -> Void in
            XCTAssertFalse(success, "persistLogToDatabase onComplete returned false success")
            expectation.fulfill()
        }

        self.waitForExpectations(timeout: 10, handler: nil)
    }

    // tests the persistLog method when database is not ready
    // In this case logs should be written to disk, and an observer should have been created watching for database ready
    func testPersistLogNotReady() {
        let logStorage = LogStorage()

        // register our mock DB service
        ServiceRouter.sharedInstance.registerService(MockDBService.self)

        // for this test we should return not ready
        MockDBService.serviceShouldReturnNotReady = true
        MockDBService.expectation = self.expectation(description: "db service called expectation")

        // ensure every log level is being written to the log system
        Logger.shared.loggerLevel = .trace

        let testString = "test log"

        Logger.info(testString)

        logStorage.persistLog(logStorage.logStore)

        self.waitForExpectations(timeout: 10, handler: nil)

        XCTAssertNotNil(logStorage.databaseReadyObserver, "database ready observer should have been created")

        XCTAssertTrue(logStorage.hasLogsOnDisk(), "Logs not found on disk when expected")
    }

    // tests the persistLog method when database is ready.
    // In this case logs should be written to database
    func testPersistLogDatabaseReady() {
        let logStorage = LogStorage()

        // register our mock connectivity service
        ServiceRouter.sharedInstance.registerService(MockDBService.self)

        // for this test we should return ready
        MockDBService.serviceShouldReturnNotReady = false
        MockDBService.expectation = self.expectation(description: "connectivity service called expectation")

        // register our mock database service
        ServiceRouter.sharedInstance.registerService(MockCDBService.self)

        // for this test we should succeed
        MockCDBService.serviceShouldReturnFailure = false
        MockCDBService.expectation = self.expectation(description: "database service called expectation")

        // ensure every log level is being written to the log system
        Logger.shared.loggerLevel = .trace

        let testString = "test log"

        Logger.info(testString)

        logStorage.persistLog(logStorage.logStore)

        self.waitForExpectations(timeout: 10, handler: nil)

        XCTAssertNil(logStorage.databaseReadyObserver, "Database ready observer should not have been created")

        XCTAssertFalse(logStorage.hasLogsOnDisk(), "Logs found on disk when not expected")
    }

    // tests conversion of logs from disk to database
    func testTransferLogsFromDiskToDatabase() {
        let logStorage = LogStorage()

        // register our mock database service
        ServiceRouter.sharedInstance.registerService(MockCDBService.self)

        // for this test we should succeed
        MockCDBService.serviceShouldReturnFailure = false
        MockCDBService.expectation = self.expectation(description: "database service called expectation")

        // ensure every log level is being written to the log system
        Logger.shared.loggerLevel = .trace

        let testString = "test log"

        Logger.info(testString)

        // write the log to disk
        logStorage.persistLogToDisk()

        // verify log was written to disk
        XCTAssertTrue(logStorage.hasLogsOnDisk(), "Logs not found on disk when expected")

        logStorage.transferLogsFromDiskToDatabase()
        self.waitForExpectations(timeout: 10, handler: nil)

        // verify logs removed from disk
        XCTAssertFalse(logStorage.hasLogsOnDisk(), "Logs found on disk when not expected")
    }

    // tests conversion of logs from disk to database ensuring if database write fails logs are not deleted
    func testTransferLogsFromDiskToDatabaseFail() {
        let logStorage = LogStorage()

        // register our mock database service
        ServiceRouter.sharedInstance.registerService(MockCDBService.self)

        // for this test we should fail
        MockCDBService.serviceShouldReturnFailure = true
        MockCDBService.expectation = self.expectation(description: "database service called expectation")

        // ensure every log level is being written to the log system
        Logger.shared.loggerLevel = .trace

        let testString = "test log"

        Logger.info(testString)

        // write the log to disk
        logStorage.persistLogToDisk()

        // verify log was written to disk
        XCTAssertTrue(logStorage.hasLogsOnDisk(), "Logs not found on disk when expected")

        logStorage.transferLogsFromDiskToDatabase()
        self.waitForExpectations(timeout: 10, handler: nil)

        // verify logs not removed from disk
        XCTAssertTrue(logStorage.hasLogsOnDisk(), "Logs not found on disk when expected")
    }

    // tests that the log is preseved when we hit the max log entries limit
    func testLogWriteOnMaxLogEntries() {
        // for this test reduce our max log entries to a smaller number
        let logStorage = LogStorage(maxLogEntries: 10)

        // We only want warning logs in this test, so other system processes don't interfere with count compared below.
        Logger.shared.loggerLevel = .warn

        // register our mock connectivity service
        ServiceRouter.sharedInstance.registerService(MockDBService.self)

        // for this test we should return not ready
        MockDBService.serviceShouldReturnNotReady = true
        MockDBService.expectation = self.expectation(description: "connectivity service called expectation")

        for count in 1...logStorage.MaxLogEntries {
            Logger.warn("test log # \(count)")
        }

        // Wait briefly, logs are written asynchronously.
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + 0.1) {
            group.leave()
        }
        group.wait()

        self.waitForExpectations(timeout: 10, handler: nil)

        //verify logs were written
        XCTAssertTrue(logStorage.hasLogsOnDisk(), "Logs not found on disk when expected")

        XCTAssertEqual(logStorage.logStore.count, 0, "Log entry count was not as expected")
    }

    // tests that previously disk-saved logs are sent to the database after it's ready
    func testDatabaseReadyObserver() {
        let logStorage = LogStorage()

        // register our mock connectivity service
        ServiceRouter.sharedInstance.registerService(MockDBService.self)

        // for now we should return not ready
        MockDBService.serviceShouldReturnNotReady = true
        MockDBService.expectation = self.expectation(description: "connectivity service called expectation")

        // ensure every log level is being written to the log system
        Logger.shared.loggerLevel = .trace

        let testString = "test log"

        Logger.info(testString)

        logStorage.persistLog(logStorage.logStore)

        self.waitForExpectations(timeout: 10, handler: nil)

        XCTAssertNotNil(logStorage.databaseReadyObserver, "Database ready observer should have been created")

        XCTAssertTrue(logStorage.hasLogsOnDisk(), "Logs not found on disk when expected")

        // register our mock database service
        ServiceRouter.sharedInstance.registerService(MockCDBService.self)

        // for this test we should succeed
        MockCDBService.serviceShouldReturnFailure = false
        MockCDBService.expectation = self.expectation(description: "database service called expectation")

        // now send pmInitialReplicationComplete notification
        NotificationCenter.default.post(name: .pmInitialReplicationComplete, object: nil)

        self.waitForExpectations(timeout: 10, handler: nil)

        XCTAssertNil(logStorage.databaseReadyObserver, "Database ready observer should have been removed")
        XCTAssertFalse(logStorage.hasLogsOnDisk(), "Logs found on disk when not expected")
    }

    func testPersistLogsOnLowMemory() {
        let logStorage = LogStorage()

        XCTAssertFalse(logStorage.hasLogsOnDisk(), "Logs found on disk when not expected")

        // ensure every log level is being written to the log system
        Logger.shared.loggerLevel = .trace

        // now logs should be going to the storeage array

        let testString = "test log"

        Logger.info(testString)

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)

        XCTAssertTrue(logStorage.hasLogsOnDisk(), "Logs not found on disk when expected")

    }

    func testPersistLogsOnBackgrounding() {
        let logStorage = LogStorage()

        XCTAssertFalse(logStorage.hasLogsOnDisk(), "Logs found on disk when not expected")

        // ensure every log level is being written to the log system
        Logger.shared.loggerLevel = .trace

        // now logs should be going to the storeage array

        let testString = "test log"

        Logger.info(testString)

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        XCTAssertTrue(logStorage.hasLogsOnDisk(), "Logs not found on disk when expected")
    }

    func testStopStoringLogs() {
        let logStorage = LogStorage()

        // ensure every log level is being written to the log system
        Logger.shared.loggerLevel = .trace

        // now logs should be going to the storeage array

        let testString = "test log"

        Logger.info(testString)

        // Wait briefly, logs are written asynchronously.
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + 0.1) {
            group.leave()
        }
        group.wait()

        // ensure we have some logs
        XCTAssertTrue(logStorage.logStore.count > 0, "No logs entries found unexpectedly")

        // stopping logging should persist what's currently in memory
        logStorage.stopStoringLogs()

        // verify we don't have any log entries
        XCTAssertTrue(logStorage.logStore.count == 0, "logs entries found unexpectedly")

        // now write more logs
        Logger.info(testString)

        // still should have no log entries
        XCTAssertTrue(logStorage.logStore.count == 0, "logs entries found unexpectedly")

    }

}

// Mock services used for testing
class MockCDBService: ServiceProtocol {
    static var expectation: XCTestExpectation?
    static var serviceShouldReturnFailure = false

    @objc static var serviceIdentifier: String {return ServiceId.CDB}

    @objc static func performRequest(_ request: URLRequest, response: HTTPURLResponse, responseReturn: @escaping responseReturnBlock, dataReturn: @escaping dataReturnBlock, requestComplete: @escaping requestCompleteBlock) {

        // tracking that we actually called the service
        if let expectation = self.expectation {
            expectation.fulfill()
        }

        if self.serviceShouldReturnFailure {
            let failResponse = HTTPURLResponse(url: response.url!, statusCode: Http.StatusCode.internalServerError.rawValue, httpVersion: Http.version, headerFields: response.allHeaderFields as? [String: String])
            responseReturn(failResponse)

            let returnDictionary = ["ok": false]

            let data = try! JSONSerialization.data(withJSONObject: returnDictionary, options: JSONSerialization.WritingOptions(rawValue: 0))

            dataReturn(data)

            requestComplete()
        } else {
            // return success
            responseReturn(response)
            let returnDictionary = ["ok": true]

            let data = try! JSONSerialization.data(withJSONObject: returnDictionary, options: JSONSerialization.WritingOptions(rawValue: 0))

            dataReturn(data)
            requestComplete()

        }

    }
}

class MockDBService: ServiceProtocol {
    static var expectation: XCTestExpectation?
    static var serviceShouldReturnNotReady = false

    @objc static var serviceIdentifier: String {return ServiceId.DB}

    @objc static func performRequest(_ request: URLRequest, response: HTTPURLResponse, responseReturn: @escaping responseReturnBlock, dataReturn: @escaping dataReturnBlock, requestComplete: @escaping requestCompleteBlock) {

        // tracking that we actually called the service
        if let expectation = self.expectation {
            expectation.fulfill()
        }

        var thisResponse = response

        if self.serviceShouldReturnNotReady {
            thisResponse = HTTPURLResponse(url: response.url!, statusCode: Http.StatusCode.notFound.rawValue, httpVersion: Http.version, headerFields: response.allHeaderFields as? [String: String])!
        }

        responseReturn(thisResponse)
        requestComplete()

    }
}
