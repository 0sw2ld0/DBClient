//
//  CoreDataDBClient.swift
//  DBClient
//
//  Created by Yury Grinenko on 03.11.16.
//  Copyright © 2016 Yalantis. All rights reserved.
//

import CoreData
import BoltsSwift

/// Describes type of model for CoreData database client.
/// Model should conform to CoreDataModelConvertible protocol
/// for ability to be fetched/saved/updated/deleted in CoreData
public protocol CoreDataModelConvertible: Stored {
    
    /// Returns type of object for model.
    static func managedObjectClass() -> NSManagedObject.Type
    
    /// Executes mapping from `NSManagedObject` instance.
    ///
    /// - Parameter managedObject: object to be mapped from.
    /// - Returns: mapped object.
    static func from(_ managedObject: NSManagedObject) -> Stored
    
    /// Executes backward mapping to `NSManagedObject` from given context
    ///
    /// - Parameters:
    ///   - context: context, where object should be created;
    ///   - existedInstance: if instance was already created it will be passed.
    /// - Returns: created instance.
    func upsertManagedObject(in context: NSManagedObjectContext, existedInstance: NSManagedObject?) -> NSManagedObject
    
    /// The name of the entity from ".xcdatamodeld"
    static var entityName: String { get }
    
    /// Decides whether primary value of object equal to given
    func isPrimaryValueEqualTo(value: Any) -> Bool
    
}

extension NSManagedObject: Stored {}

public enum MigrationType {
    
    // provide persistent store constructor with appropriate options
    case lightweight
    // in case of failure old model file will be removed
    case removeOnFailure
    // perform progressive migration with delegate
    case progressive(MigrationManagerDelegate?)
    
    public func isLightweight() -> Bool {
        switch self {
        case .lightweight:
            return true
            
        default:
            return false
        }
    }
    
}

/// Implementation of database client for CoreData storage type.
public class CoreDataDBClient {
    
    private let modelName: String
    private let bundle: Bundle
    private let migrationType: MigrationType
    private let persistentStoreType = NSSQLiteStoreType
    
    /// Constructor for client
    ///
    /// - Parameters:
    ///   - modelName: the name of the model
    ///   - bundle: the bundle which contains the model; default is main
    ///   - migrationType: migration type (in case it needed) for model; default is `MigrationType.lightweight`
    public init(forModel modelName: String, in bundle: Bundle = Bundle.main, migrationType: MigrationType = .lightweight) {
        self.modelName = modelName
        self.bundle = bundle
        self.migrationType = migrationType
    }
    
    // MARK: - CoreData stack
    
    private lazy var storeURL: URL = {
        let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let applicationDocumentsDirectory = urls[urls.count - 1]
        
        return applicationDocumentsDirectory.appendingPathComponent("\(self.modelName).sqlite")
    }()
    
    private lazy var managedObjectModel: NSManagedObjectModel = {
        guard let modelURL = self.bundle.url(forResource: self.modelName, withExtension: "momd"),
            let objectModel = NSManagedObjectModel(contentsOf: modelURL) else {
                fatalError("Can't find managedObjectModel named \(self.modelName) in \(self.bundle)")
        }
        
        return objectModel
    }()
    
    private lazy var persistentStoreCoordinator: NSPersistentStoreCoordinator = {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel:  self.managedObjectModel)
        
        if !self.isMigrationNeeded() {
            do {
                try coordinator.addPersistentStore(
                    ofType: self.persistentStoreType,
                    configurationName: nil,
                    at: self.storeURL,
                    options: nil
                )
                
                return coordinator
            } catch let error {
                fatalError("\(error)")
            }
        }
        
        // need perform migration
        do {
            try self.performMigration(coordinator)
        } catch let error {
            fatalError("\(error)")
        }
        
        return coordinator
    }()
    
    private lazy var rootContext: NSManagedObjectContext = {
        let coordinator = self.persistentStoreCoordinator
        let parentContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        parentContext.persistentStoreCoordinator = coordinator
        
        return parentContext
    }()
    
    fileprivate lazy var mainContext: NSManagedObjectContext = {
        let mainContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        mainContext.parent = self.rootContext
        
        return mainContext
    }()
    
    private lazy var readManagedContext: NSManagedObjectContext = {
        let fetchContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        fetchContext.parent = self.mainContext
        
        return fetchContext
    }()
    
    private lazy var writeManagedContext: NSManagedObjectContext = {
        let fetchContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        fetchContext.parent = self.mainContext
        
        return fetchContext
    }()
    
    // MARK: - Migration
    
    private func isMigrationNeeded() -> Bool {
        do {
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: persistentStoreType,
                at: storeURL,
                options: nil
            )
            let model = self.managedObjectModel
            
            return model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
        } catch {
            return false
        }
    }
    
    private func performMigration(_ coordinator: NSPersistentStoreCoordinator) throws {
        var options: [AnyHashable: Any]?
        if self.migrationType.isLightweight() {
            // trying to make it automatically
            options = [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true
            ]
        }
        do {
            try coordinator.addPersistentStore(
                ofType: self.persistentStoreType,
                configurationName: nil,
                at: self.storeURL,
                options: options
            )
        } catch let error {
            switch self.migrationType {
            case .removeOnFailure:
                // remove store and retry
                try? FileManager.default.removeItem(at: self.storeURL)
                try coordinator.addPersistentStore(
                    ofType: self.persistentStoreType,
                    configurationName: nil,
                    at: self.storeURL,
                    options: nil
                )
                
            case .progressive(let delegate):
                try self.performHeavyMigration(coordinator, delegate: delegate)
                
            default:
                throw error
            }
        }
    }
    
    private func performHeavyMigration(_ coordinator: NSPersistentStoreCoordinator, delegate: MigrationManagerDelegate?) throws {
        let manager = CoreDataMigrationManager()
        manager.delegate = delegate
        manager.bundle = self.bundle
        try manager.progressivelyMigrate(
            sourceStoreURL: self.storeURL,
            of: self.persistentStoreType,
            to:  self.managedObjectModel
        )
        
        let options: [AnyHashable: Any] = [
            NSInferMappingModelAutomaticallyOption: true,
            NSSQLitePragmasOption: ["journal_mode": "DELETE"]
        ]
        try coordinator.addPersistentStore(
            ofType: self.persistentStoreType,
            configurationName: nil,
            at: self.storeURL,
            options: options
        )
    }
    
    // MARK: - Read/write
    
    fileprivate func performWriteTask(_ closure: @escaping (NSManagedObjectContext, (() throws -> ())) -> ()) {
        let context = writeManagedContext
        context.perform {
            closure(context) {
                try context.save()
                try self.mainContext.save()
                try self.rootContext.save()
            }
        }
    }
    
    fileprivate func performReadTask(closure: @escaping (NSManagedObjectContext) -> ()) {
        let context = readManagedContext
        context.perform {
            closure(context)
        }
    }
    
}

// MARK: - DBClient methods

extension CoreDataDBClient: DBClient {

    public func observable<T: Stored>(for request: FetchRequest<T>) -> RequestObservable<T> {
        return CoreDataObservable(request: request, context: mainContext)
    }
    
    public func execute<T: Stored>(_ request: FetchRequest<T>) -> Task<[T]> {
        let coreDataModelType = checkType(T.self)
        
        let taskCompletionSource = TaskCompletionSource<[T]>()
        
        performReadTask { context in
            let fetchRequest = self.fetchRequest(for: coreDataModelType)
            fetchRequest.predicate = request.predicate
            fetchRequest.sortDescriptors = [request.sortDescriptor].flatMap { $0 }
            fetchRequest.fetchLimit = request.fetchLimit
            fetchRequest.fetchOffset = request.fetchOffset
            do {
                let result = try context.fetch(fetchRequest) as! [NSManagedObject]
                let resultModels = result.flatMap { coreDataModelType.from($0) as? T }
                taskCompletionSource.set(result: resultModels)
            } catch let error {
                taskCompletionSource.set(error: error)
            }
        }
        
        return taskCompletionSource.task
    }
    
    /// Insert given objects into context and save it
    /// If appropriate object already exists in DB it will be ignored and nothing will be inserted
    public func insert<T: Stored>(_ objects: [T]) -> Task<[T]> {
        checkType(T.self)
        
        let taskCompletionSource = TaskCompletionSource<[T]>()
        performWriteTask { context, savingClosure in
            var insertedObjects = [T]()
            let foundObjects = self.find(objects: objects, in: context)
            for (object, storedObject) in foundObjects {
                if storedObject != nil {
                    continue
                }
                
                _ = object.upsertManagedObject(in: context, existedInstance: nil)
                insertedObjects.append(object as! T)
            }

            do {
                try savingClosure()
                taskCompletionSource.set(result: insertedObjects)
            } catch let error {
                taskCompletionSource.set(error: error)
            }
        }
        return taskCompletionSource.task
    }
    
    /// Method to update existed in DB objects
    /// if there is no such object in db nothing will happened
    public func update<T: Stored>(_ objects: [T]) -> Task<[T]> {
        checkType(T.self)
        
        let taskCompletionSource = TaskCompletionSource<[T]>()
        performWriteTask { context, savingClosure in
            var updatedObjects = [T]()
            
            let foundObjects = self.find(objects: objects, in: context)
            for (object, storedObject) in foundObjects {
                guard let storedObject = storedObject else {
                    continue
                }
                
                _ = object.upsertManagedObject(in: context, existedInstance: storedObject)
                updatedObjects.append(object as! T)
            }
            
            do {
                try savingClosure()
                taskCompletionSource.set(result: updatedObjects)
            } catch let error {
                taskCompletionSource.set(error: error)
            }
        }
        return taskCompletionSource.task
    }
    
    /// Update object if it exists or insert new one otherwise
    public func upsert<T: Stored>(_ objects: [T]) -> Task<(updated: [T], inserted: [T])> {
        checkType(T.self)
        
        let taskCompletionSource = TaskCompletionSource<(updated: [T], inserted: [T])>()
        performWriteTask { context, savingClosure in
            var updatedObjects = [T]()
            var insertedObjects = [T]()
            let foundObjects = self.find(objects: objects, in: context)
            
            for (object, storedObject) in foundObjects {
                _ = object.upsertManagedObject(in: context, existedInstance: storedObject)
                if storedObject == nil {
                    insertedObjects.append(object as! T)
                } else {
                    updatedObjects.append(object as! T)
                }
            }
            
            do {
                try savingClosure()
                taskCompletionSource.set(result: (updated: updatedObjects, inserted: insertedObjects))
            } catch let error {
                taskCompletionSource.set(error: error)
            }
        }
        
        return taskCompletionSource.task
    }
    
    /// For each element in collection:
    /// After all deletes try to save context
    public func delete<T: Stored>(_ objects: [T]) -> Task<Void> {
        checkType(T.self)
        
        let taskCompletionSource = TaskCompletionSource<Void>()
        performWriteTask { context, savingClosure in
            let foundObjects = self.find(objects, in: context)
            foundObjects.forEach { context.delete($0) }
            
            do {
                try savingClosure()
                taskCompletionSource.set(result: ())
            } catch let error {
                taskCompletionSource.set(error: error)
            }
        }
        
        return taskCompletionSource.task
    }
    
}

private extension CoreDataDBClient {
    
    func fetchRequest(for entity: CoreDataModelConvertible.Type) -> NSFetchRequest<NSFetchRequestResult> {
        return NSFetchRequest(entityName: entity.entityName)
    }
    
    @discardableResult
    func checkType<T>(_ inputType: T) -> CoreDataModelConvertible.Type {
        switch inputType {
        case let type as CoreDataModelConvertible.Type:
            return type
            
        default:
            let modelType = String(describing: CoreDataDBClient.self)
            let protocolType = String(describing: CoreDataModelConvertible.self)
            let givenType = String(describing: inputType)
            fatalError("`\(modelType)` can manage only types which conform to `\(protocolType)`. `\(givenType)` given.")
        }
    }
    
    func find<T: Stored>(_ objects: [T], in context: NSManagedObjectContext) -> [NSManagedObject] {
        let coreDataModelType = checkType(T.self)
        guard let primaryKeyName = T.primaryKeyName else {
            return []
        }
        
        let ids = objects.flatMap { $0.valueOfPrimaryKey }
        let fetchRequest = self.fetchRequest(for: coreDataModelType)
        fetchRequest.predicate = NSPredicate(format: "\(primaryKeyName) IN %@", ids)
        guard let result = try? context.fetch(fetchRequest), let storedObjects = result as? [NSManagedObject] else {
            return []
        }
        
        return storedObjects
    }
    
    func find<T: Stored>(objects: [T], in context: NSManagedObjectContext) -> [(object: CoreDataModelConvertible, storedObject: NSManagedObject?)] {
        guard let primaryKeyName = T.primaryKeyName else {
            return []
        }
        
        let storedObjects = find(objects, in: context)
        
        return convert(objects: objects).map { object -> (CoreDataModelConvertible, NSManagedObject?) in
            let managedObject = storedObjects.first(where: { (obj: NSManagedObject) -> Bool in
                if let value = obj.value(forKey: primaryKeyName) {
                    return object.isPrimaryValueEqualTo(value: value)
                }
                
                return false
            })
            
            return (object, managedObject)
        }
    }
    
    func convert<T: Stored>(objects: [T]) -> [CoreDataModelConvertible] {
        checkType(T.self)
        
        return objects.flatMap { $0 as? CoreDataModelConvertible }
    }
    
}
