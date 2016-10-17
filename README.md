## Predix Mobile iOS Example -- Storing logs in the client database

By default the PredixMobileSDK logging system writes logs to the standard iOS console, however the logging system is extensible. This examples demonstrates a mechanism to send client logs to the local database as documents, where they will be replicated to the Predix Mobile backend.

There are many ways to write logs to the database, but some considerations are:
* Every time a document is edited it creates a revision. Since logging is a high-frequency write operation, we want to minimize document revisions.
* Logging may occur before the database is initialized.
* Logging should be aware of system events such as backgrounding and low-memory situations.

While there are many designs that could address these considerations, for this example we're taking this approach:
* Logging will store log entries in memory, until a certain number of entries is created.
* Once our entry threshold is met, logs will attempt to be written to the database.
* Each log entry block will be a new document--documents will not be updated once created.
* If the system cannot write to the database, the log document will be written temporarily to disk, when the database becomes available these temporary files will be added to the database
* When the app is notified of low-memory or backgrounding, any current log entries in memory will be stored as a disk document regardless of the number of entries.

Ideally a process on the backend would sweep these log documents into a server-side logging system where they could be available for analysis and troubleshooting, and purge the documents after sweeping to avoid needless replication. This example does not cover those operations, it focuses solely on the client-side storage of the logs entries.
###Before you begin
To get started, follow this documentation:
* [Get Started with the Mobile Service and Mobile SDK] (https://www.predix.io/docs#rae4EfJ6) 
* [Running the Predix Mobile Sample App] (https://www.predix.io/docs#EGUzWwcC)
* [Creating a Mobile Hello World Webapp] (https://www.predix.io/docs#DrBWuHkl) 

###How to use this example:
Add the file `LogStorage.swift` to your Predix Mobile container Xcode project, and the file `LogStorageTests.swift` to your container's unit tests.

Then add this property to your AppDelegate:

    // override logging behavior, store logs in the database
    var logStorage : LogStorage = LogStorage()

That's really all that's needed. The LogStorage class automatically takes over logging operations when it's initialized.

#####Explore the code for full details.

