import Foundation
import FMDB

public enum DBError: Error {
  case openFailed, dbPathInvalid, missingDBQueue, restoreFailed, recreateFailed, pushFailed, popFailed
}

public enum QueryError: Error {
  case failed(errorCode: Int)
  case missingKey
  case keyIsNull(fieldName: String)
}

public enum StatementType {
  case query, update
}

public struct StatementParts {
  let sql: String
  let values: Array<Any>
  let type: StatementType
  
  public init(sql: String, values: Array<Any>, type: StatementType) {
    self.sql = sql
    self.values = values
    self.type = type
  }
}

public struct DBMeta {
  public var queue: FMDatabaseQueue
  public var path: String?
}

@objc
public class DBManager: NSObject {
  public static var shouldReplaceDuplicates = false
  private static var dbs: Array<DBMeta> = []
  private static var isRetry: Bool = false

  private static var currentQueue: FMDatabaseQueue? {
    get {
      return dbs.last?.queue
    }
  }
  
  public class func push(_ dbPath: String?, dbDefFilePaths: Array<String>?) throws {
    guard dbs.count > 0 else {
      throw DBError.pushFailed
    }
    
    try open(dbPath, dbDefFilePaths: dbDefFilePaths)
  }
  
  public class func pop(deleteDB: Bool) throws {
    guard dbs.count > 1 else {
      print("Can't pop a database if there isn't more than one db open.")
      throw DBError.popFailed
    }
    
    close(deleteDB: deleteDB)
  }

  @discardableResult
  public class func open(_ dbPath: String?, dbDefFilePaths: Array<String>?, pushOnStack: Bool = true) throws -> DBMeta? {
    print("Open database queue at: \(dbPath ?? "IN_MEMORY_DB")")

    guard let queue = FMDatabaseQueue(path: dbPath) else {
      throw DBError.dbPathInvalid
    }

    var upgradeFailed = false
    queue.inDatabase({ (db) -> Void in
      let startSchemaVersion = Int((db?.userVersion())!)
      var currentSchemaVersion = startSchemaVersion

      if let defPaths = dbDefFilePaths {
        for (fileCount, path) in defPaths.enumerated() {
          let newVersionNum = fileCount + 1
          if currentSchemaVersion < newVersionNum { //un-processed def file
            do {
              db?.beginTransaction()
              let sql = try String(contentsOfFile:path, encoding: String.Encoding.utf8)
              let sqlStatements = sql.components(separatedBy: ";")
              let fileName = NSString(string: path).lastPathComponent

              for (stmtCount, statement) in sqlStatements.enumerated() {
                let trimmedStatement = statement.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                if trimmedStatement.utf8.count > 0 {
                  print("\nExecuting SQL Statement (\(fileName) : \(stmtCount))\n\(trimmedStatement)")
                  try db?.executeUpdate(trimmedStatement, values: nil)
                }
              }

              db?.commit()
              currentSchemaVersion = newVersionNum
              db?.setUserVersion(UInt32(currentSchemaVersion))

            } catch {
              upgradeFailed = true
              if isRetry {
                print("DBSetupFailed currentVersion=\(startSchemaVersion) to newVersion=\(newVersionNum)")
              } else {
                print("DBUpgradeFailed currentVersion=\(startSchemaVersion) to newVersion=\(newVersionNum)")
              }
              return
            }
          }
        }
      }

      if(startSchemaVersion != currentSchemaVersion) {
        print("Successfully updated db schema to version v\(currentSchemaVersion)")
      } else {
        print("Database is current at version v\(startSchemaVersion)")
      }
    })

    var dbMeta: DBMeta?
    if upgradeFailed {
      if isRetry { //retry failed so don't retry again
        throw DBError.restoreFailed

      } else {
        print("Error upgrading db to latest version.  Removing database and reinitializing.")
        self.close()

        if let dbPath = dbPath {
          do {
            try FileManager.default.removeItem(atPath: dbPath)
          } catch {
            print("Error trying to remove main db: \(dbPath)")
          }
        }
        isRetry = true
        do {
          dbMeta = try self.open(dbPath, dbDefFilePaths: dbDefFilePaths, pushOnStack: pushOnStack)
        } catch {
          print("Error trying to recreate main db: \(dbPath)")
          throw DBError.recreateFailed
        }
        return dbMeta
      }
    }

    dbMeta = DBMeta(queue: queue, path: dbPath)
    if let dbMeta = dbMeta, pushOnStack {
      dbs.append(dbMeta)
    }
    return dbMeta
  }
  
  public class func close() {
    while dbs.count > 0 {
      close(deleteDB: dbs.count > 1)
    }
  }

  private class func close(deleteDB: Bool = false) {
    if let dbMeta = dbs.popLast() {
      dbMeta.queue.close()
      if let path = dbMeta.path, deleteDB {
        do {
          try FileManager.default.removeItem(atPath: path)
        } catch {
          print("Can't delete db file (\(path)): \(error)")
        }
      }
    }
  }

  public class func getDBPath(_ fileName: String) -> String? {
    if let documentsPath = NSSearchPathForDirectoriesInDomains(FileManager.SearchPathDirectory.documentDirectory, FileManager.SearchPathDomainMask.userDomainMask, true).first {
      let dbPath = documentsPath.appending("/\(fileName).sqlite3")
      return dbPath
    }
    return nil
  }

  public class func getDBDefFiles(bundle: Bundle?) -> Array<String>? {
    let pathBundle = bundle ?? Bundle.main
    var paths = pathBundle.paths(forResourcesOfType: "sql", inDirectory: nil)
    paths.sort()
    return paths
  }

  public class func getDBQueue() throws -> FMDatabaseQueue {
    guard let queue = currentQueue else {
      print("DB Queue was not initialized so we can't return it")
      throw DBError.missingDBQueue
    }
    return queue
  }

  public class func truncateAllTables(excludes: Array<String> = []) {
    guard let queue = try? getDBQueue() else { return }

    queue.inDatabase { (db) in
      let result = db?.getSchema()
      while (result?.next())! {
        if let type = result?.string(forColumn: "type") , type == "table" {
          if let tableName = result?.string(forColumn: "name"), !excludes.contains(tableName) {
            do {
              try db?.executeUpdate("DELETE FROM \(tableName)", values: nil)
              print("Truncated data from the '\(tableName)' table.")
            } catch {
              print("Error truncating data in the '\(tableName)' table.")
            }
          }
        }
      }
    }
  }

  public class func executeUpdateQuery(_ query: String, params: Any...) {
    do {
      try executeStatement(StatementParts(sql: query, values: params, type: .update), resultHandler: {_ in })
    } catch {
      print("Failed to update db (query): \(error)")
    }
  }

  public class func resultDictionariesFromQuery(_ query: String, params: Any...) -> Array<NSDictionary> {
    var resultDicts = [NSDictionary]()
    do {
      try executeStatement(StatementParts(sql: query, values: params, type: .query), resultHandler: { (result) in
        while (result?.next())! {
          if let resultDict = result?.resultDictionary() {
            resultDicts.append(resultDict as NSDictionary)
          }
        }
      })
    } catch {
      print("Failed to query db (query): \(error)")
    }
    return resultDicts
  }

  public class func executeStatement(_ statement: StatementParts, resultHandler: @escaping (_ result: FMResultSet?) -> ()) throws -> Void {
    try executeStatements([statement]) { (results) in
      if let result = results.first {
        resultHandler(result)
      } else {
        resultHandler(nil)
      }
    }
  }

  public class func executeStatements(_ statements: Array<StatementParts>, resultsHandler: @escaping (_ results: Array<FMResultSet?>) -> ()) throws -> Void {
    let queue = try getDBQueue()
    var transactionError: Error?

    queue.inTransaction { (db, rollback) in
      var results = [FMResultSet?]()
      do {
        for statement in statements {
          switch statement.type {
            case .query:
              let result = try db?.executeQuery(statement.sql, values: statement.values)
              results.append(result)
            case .update:
              try db?.executeUpdate(statement.sql, values: statement.values)
              results.append(nil)
          }
        }
        resultsHandler(results)

        for result in results {
          result?.close()
        }

      } catch {
        print("Failed to query/update db: \(error)")
        rollback?.initialize(to: true)
        transactionError = QueryError.failed(errorCode: Int((db?.lastErrorCode())!))
      }
    }

    if let transactionError = transactionError {
      throw transactionError
    }
  }

  //MARK: OBJC compatibility

  public class func executeUpdateQuery_Objc(_ query: String, args:[Any])
  {
    do {
      try executeStatement(StatementParts(sql: query, values: args, type: .update), resultHandler: {_ in })
    } catch {
      print("Failed to update db (query): \(error)")
    }
  }

  public class func resultDictionariesFromQuery_Objc(_ query: String, args:[Any]) -> Array<NSDictionary> {
    var resultDicts = [NSDictionary]()
    do {
      try executeStatement(StatementParts(sql: query, values: args, type: .query), resultHandler: { (result) in
        while (result?.next())! {
          if let resultDict = result?.resultDictionary() {
            resultDicts.append(resultDict as NSDictionary)
          }
        }
      })
    } catch {
      print("Failed to query db (query): \(error)")
    }
    return resultDicts
  }
}
