//
//  LogStorage.swift
//  PredixMobileReferenceApp
//
//  Created by Johns, Andy (GE Corporate) on 2/22/16.
//  Copyright © 2016 GE. All rights reserved.
//

/*
This example class interacts with the PredixMobileSDK for iOS to preserve client logs in the database.

First it hooks into the PredixMobileSDK logging system to replace the default logging mechanism
Then it stores logs in memory until it has MaxLogEntries number of log entries.
Then if the database is available, it will store the logs entries in a document in the database.
if the database is not available it will store the log entries on disk, and watch for the database to be ready.
When the database is ready, existing disk-persisted logs will be written to the database.
*/

import Foundation
import PredixMobileSDK

// default number of log entries to store in memory before writing to a document
private let DefaultMaxLogEntries = 10000

// These keys will be used when creating the log document. 
// The document is created in the logArrayToJSON method.
struct LogDocumentKeys {
    // Logs is an array of log entries
    static let Logs: String = "logs"

    // The bundle id of the application
    static let BundleId: String = "bundle_id"

    // the vendor device id of the current device
    static let DeviceId: String = "device_id"

    // The document type
    static let DocumentType: String = "type"
}

// Each log entry is a dictionary, containing these keys
struct LogEntryKeys {
    // Date/time when the log entry was created
    static let Date: String = "date"

    // The log message
    static let LogEntry: String = "log"
}

internal class LogStorage {
    // properties:

    // The number of log entries stored in memory before a log document will be created.
    let MaxLogEntries: Int

    // The subdirectory where log documents will be written to disk if the database is unavailable.
    let LogPersistancePath = "logstorage"

    // The document type all log documents will use
    let LogDocumentType = "client-logs"

    // NSNotificationCenter observers
    var databaseReadyObserver: NSObjectProtocol?
    var memoryObserver: NSObjectProtocol?
    var backgroundingObserver: NSObjectProtocol?

    // memory storage for the logs
    var logStore: [[String: Any]] = []

    // formatter for the log date
    lazy var logDataFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-mm-dd hh:MM:ss.SSS"
        return formatter
    }()

    // location where log documents are written to disk if the database is unavailable.
    lazy var logLocation: URL = {
        return PredixMobilityConfiguration.localStorageURL.appendingPathComponent(self.LogPersistancePath)
    }()

    // MARK: Initialization and Deinitialization

    init(maxLogEntries: Int) {
        self.MaxLogEntries = maxLogEntries
        self.setupLogStorage()
    }

    convenience init() {
        self.init(maxLogEntries: DefaultMaxLogEntries)
    }

    deinit {
        self.clearObservers()
    }

    // MARK: Internal methods

    //Stop persisting logs and restore the default log writing mechanism
    func stopStoringLogs() {
        (Logger.shared as! Logger).setLogLineWriterClosure(nil)
        self.clearObservers()
        self.clearAndPersistLog()
    }

    // Persists the given log entries as a document, either to disk or the database as available.
    // if the database is unavailable an observer will be created to watch for when the database is ready.
    func persistLog(_ logStore: [[String: Any]]) {
        // if database is ready then store the logs directly in the database, otherwise store on disk

        if let logData = self.logArrayToJSON(logStore) {
            var responseStatus: Http.StatusCode?

            // query database to see if replication is configured. If not, then the database isn't ready.
            ServiceRouter.sharedInstance.processRequest(ServiceId.DB, extraPath: "~/replication", method: "GET", data: nil, responseBlock: { (response : URLResponse?) -> Void in

                if let response = response as? HTTPURLResponse {
                    responseStatus = Http.StatusCode(rawValue: response.statusCode)
                }
                }, dataBlock: { (_ : Data?) -> Void in
                    // we don't care about the data here, just the status
                }) { () -> Void in

                    if let responseStatus = responseStatus, responseStatus == Http.StatusCode.ok {
                        // store the logs in the database
                        self.persistLogToDatabase(logData)
                        return
                    }

                    // persist the logs on disk, and watch for the database to be ready status
                    self.persistLogToDisk(logData)
                    self.createDatabaseReadyObserver()

            }
        }
    }

    // Creates the database ready observer by listening for the InitialReplicationCompleteNotification
    // When the notification is observed, will start the process of transfering log documents from disk to the database
    func createDatabaseReadyObserver() {
        if self.databaseReadyObserver == nil {
            unowned let unownedSelf = self

            self.databaseReadyObserver = NotificationCenter.default.addObserver(forName: .pmInitialReplicationComplete, object: nil, queue: nil, using: { (_: Notification) -> Void in

                // now that the database is ready we don't need to watch for it anymore
                unownedSelf.removeObserver(&self.databaseReadyObserver)
                unownedSelf.transferLogsFromDiskToDatabase()

            })
        }
    }

    // Persists log documents already serialized to NSData objects to the database
    func persistLogToDatabase(_ data: Data) {
        self.persistLogToDatabase(data, onComplete: nil)
    }

    // Persists log documents already serialized to NSData objects to the database, with a closure so callers can know when the process is complete, and if it was successful.
    func persistLogToDatabase(_ data: Data, onComplete: ((Bool) -> Void)?) {
        var responseStatus: Http.StatusCode?
        var responseDictionary: [String: Any]?

        ServiceRouter.sharedInstance.processRequest(ServiceId.CDB, extraPath: "~", method: "POST", data: data, responseBlock: { (response : URLResponse?) -> Void in
            if let response = response as? HTTPURLResponse {
                responseStatus = Http.StatusCode(rawValue: response.statusCode)
            }
            }, dataBlock: { (data: Data?) -> Void in
                if let data = data {
                    responseDictionary = (try? JSONSerialization.jsonObject(with: data, options: JSONSerialization.ReadingOptions(rawValue: 0))) as? [String : Any]
                }
            }, completionBlock: { () -> Void in

                var success = true
                if responseStatus != Http.StatusCode.created && responseDictionary?["ok"] as? Bool != true {
                    Logger.error("Error creating log document: status: \(String(describing: responseStatus)) response dictionary: \(responseDictionary ?? [:])")
                    success = false
                }

                if let onComplete = onComplete {
                    onComplete(success)
                }

        })
    }

    // Persists logs in the logStore property to disk, and clears the logStore property
    func persistLogToDisk() {
        let storeCopy = self.logStore
        self.logStore.removeAll()
        if let logData = self.logArrayToJSON(storeCopy) {
            self.persistLogToDisk(logData)
        }
    }

    // Persists log documents already serialized to NSData objects to disk
    func persistLogToDisk(_ data: Data) {
        let logFile = self.logLocation.appendingPathComponent(UUID().uuidString).path
        if !FileManager.default.createFile(atPath: logFile, contents: data, attributes: [FileAttributeKey(rawValue: FileAttributeKey.protectionKey.rawValue): FileProtectionType.completeUntilFirstUserAuthentication]) {
            Logger.error("Persisting logs to disk returned false. Logs will be lost")
        }
    }

    // Determines if any log documents are on disk
    func hasLogsOnDisk() -> (Bool) {
        if let files = try? FileManager.default.contentsOfDirectory(at: self.logLocation, includingPropertiesForKeys: nil, options: FileManager.DirectoryEnumerationOptions(rawValue: 0)) {
            return files.count > 0
        }
        return false
    }

    // Reads log documents from the disk, and stores them in the database. If the database write is successful the log document is deleted from disk.
    func transferLogsFromDiskToDatabase() {
        do {
            let fileManager = FileManager.default
            let files = try fileManager.contentsOfDirectory(at: self.logLocation, includingPropertiesForKeys: nil, options: FileManager.DirectoryEnumerationOptions(rawValue: 0))

            for file in files {
                if let logData = try? Data(contentsOf: URL(fileURLWithPath: file.path)) {
                    self.persistLogToDatabase(logData, onComplete: { (success: Bool) -> Void in
                        if success {
                            do {
                                try fileManager.removeItem(at: file)
                            } catch let error {
                                Logger.error("Error deleting persisted log file: \(error)")
                            }
                        }
                    })
                }
            }

        } catch let error {
            Logger.error("Error reading log files from disk: \(error)")
        }
    }

    // Takes an array of log entries and creates a log document dictionary
    func logArrayToJSON(_ logArray: [[String: Any]]) -> (Data?) {
        // exit if logArray is somehow invalid
        if JSONSerialization.isValidJSONObject(logArray) {
            let deviceId = UIDevice.current.identifierForVendor!.uuidString
            let bundleId = Bundle.main.bundleIdentifier!

            let logDocument: [String: Any] = [LogDocumentKeys.DeviceId: deviceId, LogDocumentKeys.BundleId: bundleId, LogDocumentKeys.DocumentType: self.LogDocumentType, LogDocumentKeys.Logs: logArray]

            // since we're checking for a valid object above, it's unlikely we'll have an error here, so skipping do/catch for optional syntax
            return try? JSONSerialization.data(withJSONObject: logDocument, options: JSONSerialization.WritingOptions(rawValue: 0))
        } else {
            Logger.error("Unable to persist log array. Log array is not a valid JSON object")
        }
        return nil
    }

    // Compare the number of log entries in the logStore property to the MaxLogEntries.
    // If the threshold has been surpassed, calles clearAndPersistLog method
    func persistLogIfNeeded() {
        // if we have our max count of log entries then we'll persist the log. This logic could be different, for example date-based instead
        if self.logStore.count >= MaxLogEntries {
            self.clearAndPersistLog()
        }
    }

    // Writes a single log entry, then validiates if the logging threshold has been surpassed.
    func storeLogMsg(_ msg: String, date: Date) {
        // Storing the log message, and date/time separately. Could store other information per-line information here too if needed.
        let dateString = self.logDataFormatter.string(from: date)

        self.logStore.append([LogEntryKeys.Date: dateString as Any, LogEntryKeys.LogEntry: msg as Any])

        self.persistLogIfNeeded()
    }

    // MARK: Private methods

    // Cleans up all NSNotificationCenter observers used.
    fileprivate func clearObservers() {
        // Clean up observers
        self.removeObserver(&self.databaseReadyObserver)
        self.removeObserver(&self.memoryObserver)
        self.removeObserver(&self.backgroundingObserver)
    }

    // Removes a NSNotificationCenter observer
    fileprivate func removeObserver(_ observerProperty : inout NSObjectProtocol?) {
        if let observer = observerProperty {
            observerProperty = nil
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // Initailizes the log storage system by hooking the Logger writer block, 
    // creating observers for low memory and backgrounding, and ensures the disk 
    // location for log documents is created.
    fileprivate func setupLogStorage() {
        self.memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil, using: {[weak self] (_:Notification) -> Void in
            // when running out of memory quickly dump the logs to disk
            self?.persistLogToDisk()
        })

        self.backgroundingObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil, using: {[weak self] (_:Notification) -> Void in
            // if going to background, quickly dump the logs to disk
            self?.persistLogToDisk()
        })

        // Create disk log file directory if needed
        _ = try? FileManager.default.createDirectory(at: self.logLocation, withIntermediateDirectories: true, attributes: nil)

        // if we have logs on disk at startup, then create a database ready observer, so when the database is ready we'll automatically transfer the logs
        if self.hasLogsOnDisk() {
            self.createDatabaseReadyObserver()
        }

        // Hooks the PredixMobileSDK logging system, replacing the default logging
        (Logger.shared as! Logger).setLogLineWriterClosure {[weak self] (logLine: String) in
            print(logLine)

            // store current time and log message as tuple
            self?.storeLogMsg(logLine, date: Date())
        }
    }

    // Clears the existing logStore array, and persists the previously written logs entries
    fileprivate func clearAndPersistLog() {
        let storeCopy = self.logStore
        self.logStore.removeAll()
        self.persistLog(storeCopy)
    }

}
