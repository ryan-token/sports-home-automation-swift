//
//  SharedUtils.swift
//  sports-home-automation-swift
//
//  Created by Ryan Token on 2/6/25.
//

import Extensions
import Foundation

// Computed on every read, not stored: a warm Lambda container lives for hours, so a stored global would keep
// the season it saw at cold start across a month boundary.

// Football season = August through February
public var isFootballSeason: Bool {
    let month = Date().month
    return (8...12).contains(month) || (1...2).contains(month)
}

// Basketball season = October through April 15
public var isBasketballSeason: Bool {
    let today = Date()
    return (10...12).contains(today.month) || (1...3).contains(today.month) || (today.month == 4 && today.day <= 15)
}
