//
//  User.swift
//  DBClient-Example
//
//  Created by Roman Kyrylenko on 1/6/17.
//  Copyright © 2017 Yalantis. All rights reserved.
//

import Foundation
import DBClient

class User {

    let name: String
    let id: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

}

extension User: Stored {

    public static var primaryKey: String? { return "id" }

}
