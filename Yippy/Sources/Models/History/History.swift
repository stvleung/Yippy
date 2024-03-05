//
//  History.swift
//  Yippy
//
//  Created by Matthew Davidson on 16/10/19.
//  Copyright © 2019 MatthewDavidson. All rights reserved.
//

import Foundation
import Cocoa
import RxSwift
import RxRelay

/// Representation of all the history
class History {
    
    private var _items = [HistoryItem]()
    
    /// Behaviour relay for the last change count of the pasteboard.
    /// Private so that it cannot be manipulated outside of the class.
    private var _lastRecordedChangeCount = BehaviorRelay<Int>(value: -1)
    
    /// Observable for the last recorded change count of the pasteboard.
    var observableLastRecordedChangeCount: Observable<Int> {
        return _lastRecordedChangeCount.asObservable()
    }
    
    /// The last change count for which the items on the pasteboard have been added to the history.
    var lastRecordedChangeCount: Int {
        return _lastRecordedChangeCount.value
    }
    
    /// The file manager for the storage of pasteboard history.
    var historyFM: HistoryFileManager
    
    /// The cache for the history item.
    var cache: HistoryCache
    
    private var _maxItems: BehaviorRelay<Int>
    
    var items: [HistoryItem] {
        get {
            return self._items
        }
    }
    
    var maxItems: Observable<Int> {
        _maxItems.asObservable()
    }
    
    enum Change {
        case initial
        case insert(index: Int)
        case delete(deletedItem: HistoryItem)
        case clear
        case move(from: Int, to: Int)
        case itemLimitDecreased(deletedItems: [HistoryItem])
    }
    
    typealias SubscribeHandler = ([HistoryItem], Change) -> Void
    private var subscribers = [SubscribeHandler]()
    
    private let bundleIdDenylist = [String]()
    /// If a pasteboard item's types contains any of these, it will not be saved.
    private let pasteboardTypeDenylist: Set = [
        "org.nspasteboard.TransientType",
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
        "com.typeit4me.clipping",
        "de.petermaurer.TransientPasteboardType",
        "Pasteboard generator type",
        "net.antelle.keeweb",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.8bit.bitwarden",
        "com.hicknhacksoftware.MacPass",
        "com.keepassium.ios",
    ]
    /// These pasteboard item types will not be saved.
    private let pasteboardTypeIgnoreList = Set([
        "dyn.ah62d4rv4gu8zg55zsmv0nvperf4g86varvu0635zqfx0nkdsqf00nkduqf31k3pcr7u1e3basv61a3k",
    ].map({NSPasteboard.PasteboardType(rawValue: $0)}));
    
    init(historyFM: HistoryFileManager = .default, cache: HistoryCache, items: [HistoryItem], maxItems: Int = Constants.system.maxHistoryItems) {
        self.historyFM = historyFM
        self.cache = cache
        self._items = items
        self._maxItems = BehaviorRelay<Int>(value: maxItems)
        
        if items.count > maxItems {
            reduceHistory(to: maxItems)
        }
    }
    
    static func load(historyFM: HistoryFileManager = .default, cache: HistoryCache) -> History {
        return historyFM.loadHistory(cache: cache)
    }
    
    func subscribe(onNext: @escaping SubscribeHandler) {
        subscribers.append(onNext)
        onNext(_items, Change.initial)
    }
    
    func insertItem(_ item: HistoryItem, at i: Int) {
        _items.insert(item, at: i)
        subscribers.forEach({$0(_items, Change.insert(index: i))})
        historyFM.insertItem(newHistory: _items, at: i)
        
        if _items.count > _maxItems.value {
            let deletedItem = _items[_items.count - 1]
            deleteItem(at: _items.count - 1)
            subscribers.forEach({$0(_items, Change.delete(deletedItem: deletedItem))})
        }
    }
    
    func deleteItem(at i: Int) {
        let removed = _items.remove(at: i)
        subscribers.forEach({$0(_items, Change.delete(deletedItem: removed))})
        historyFM.deleteItem(newHistory: _items, deleted: removed)
    }
    
    func clear() {
        _items.forEach({$0.stopCaching()})
        _items = []
        subscribers.forEach({$0(_items, Change.clear)})
        historyFM.clearHistory()
    }
    
    func moveItem(at i: Int, to j: Int) {
        let item = _items.remove(at: i)
        _items.insert(item, at: j)
        subscribers.forEach({$0(_items, Change.move(from: i, to: j))})
        historyFM.moveItem(newHistory: _items, from: i, to: j)
    }
    
    func recordPasteboardChange(withCount changeCount: Int) {
        _lastRecordedChangeCount.accept(changeCount)
    }
    
    func setMaxItems(_ maxItems: Int) {
        if maxItems < _maxItems.value {
            reduceHistory(to: maxItems)
        }
        _maxItems.accept(maxItems)
    }
    
    private func reduceHistory(to maxItems: Int) {
        guard _items.count > maxItems else {
            return;
        }
        historyFM.reduce(oldHistory: _items, toSize: maxItems)
        let deletedItems = Array(_items.suffix(_items.count - maxItems))
        _items = Array(_items.prefix(maxItems))
        subscribers.forEach({$0(_items, Change.itemLimitDecreased(deletedItems: deletedItems))})
    }
}

extension History: PasteboardMonitorDelegate {
    
    func pasteboardDidChange(_ pasteboard: NSPasteboard, originBundleId: String?) {
        // Check if we made this pasteboard change, if so, ignore
        if pasteboard.changeCount == lastRecordedChangeCount {
            return
        }
        
        // Check there are items on the pasteboard
        guard let items = pasteboard.pasteboardItems else {
            return
        }
        
        for item in items {
            let filteredTypes = Set(item.types).subtracting(self.pasteboardTypeIgnoreList)
            let hasTypes = !filteredTypes.isEmpty
            let hasNoDeniedTypes = Set(filteredTypes.map({ $0.rawValue })).isDisjoint(with: pasteboardTypeDenylist)
            
            if hasTypes && hasNoDeniedTypes {
                var data = [NSPasteboard.PasteboardType: Data]()
                for type in filteredTypes {
                    if let d = item.data(forType: type) {
                        let firstData = self._items.first?.data(forType: type)
                        let isNewData = firstData == nil || firstData?.hashValue != d.hashValue
                        if isNewData {
                            data[type] = d
                        }
                    }
                    else {
                        print("Warning: new pasteboard data nil for type '\(type.rawValue)'")
                    }
                }
                if !data.isEmpty {
                    let historyItem = HistoryItem(unsavedData: data, cache: cache)
                    insertItem(historyItem, at: 0)
                }
            }
        }
        
        // Save pasteboard change count
        recordPasteboardChange(withCount: pasteboard.changeCount)
    }
}
