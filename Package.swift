// swift-tools-version: 6.0
// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License version 3 as
// published by the Free Software Foundation. It is distributed WITHOUT ANY
// WARRANTY; see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: AGPL-3.0-only
//
// MPPKit — native Microsoft Project (.mpp) reading and writing for Apple platforms.
//
// Targets macOS and iPadOS; the format layer is pure Swift with no platform
// dependencies beyond Foundation.

import PackageDescription

let package = Package(
    name: "MPPKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "MPPKit", targets: ["MPPKit"]),
        .executable(name: "mppdump", targets: ["mppdump"]),
    ],
    targets: [
        // MS-CFB / OLE2 compound-file container: reader and writer.
        .target(name: "MPPCFB"),

        // Format-independent project model.
        .target(name: "MPPModel"),

        // The MPP14 (Project 2010 through Microsoft 365) binary layout.
        .target(name: "MPP14", dependencies: ["MPPCFB", "MPPModel"]),

        // Gantt geometry, spatial index and timescale: no UI framework.
        .target(name: "MPPGantt", dependencies: ["MPPModel"]),

        // Umbrella module for app consumption.
        .target(name: "MPPKit", dependencies: ["MPPCFB", "MPPModel", "MPP14", "MPPGantt"]),

        // Reverse-engineering / inspection CLI.
        .executableTarget(name: "mppdump", dependencies: ["MPPKit"]),

        .testTarget(name: "MPP14Tests", dependencies: ["MPPKit"]),
    ]
)
