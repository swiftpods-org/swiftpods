import Foundation

/// A small project as Xcode writes it: an iOS app, a static library and a unit test bundle.
public enum Fixtures {
    public static let project = """
        // !$*UTF8*$!
        {
        	archiveVersion = 1;
        	classes = {
        	};
        	objectVersion = 60;
        	objects = {

        /* Begin PBXBuildFile section */
        		A10000000000000000000001 /* main.swift in Sources */ = {isa = PBXBuildFile; fileRef = A20000000000000000000001 /* main.swift */; };
        /* End PBXBuildFile section */

        /* Begin PBXFileReference section */
        		A20000000000000000000001 /* main.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };
        		A20000000000000000000002 /* App.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = App.app; sourceTree = BUILT_PRODUCTS_DIR; };
        		A20000000000000000000003 /* libPlugin.a */ = {isa = PBXFileReference; explicitFileType = archive.ar; includeInIndex = 0; path = libPlugin.a; sourceTree = BUILT_PRODUCTS_DIR; };
        		A20000000000000000000004 /* AppTests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = AppTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
        /* End PBXFileReference section */

        /* Begin PBXFrameworksBuildPhase section */
        		A30000000000000000000001 /* Frameworks */ = {
        			isa = PBXFrameworksBuildPhase;
        			buildActionMask = 2147483647;
        			files = (
        			);
        			runOnlyForDeploymentPostprocessing = 0;
        		};
        /* End PBXFrameworksBuildPhase section */

        /* Begin PBXGroup section */
        		A40000000000000000000001 = {
        			isa = PBXGroup;
        			children = (
        				A20000000000000000000001 /* main.swift */,
        				A40000000000000000000002 /* Products */,
        			);
        			sourceTree = "<group>";
        		};
        		A40000000000000000000002 /* Products */ = {
        			isa = PBXGroup;
        			children = (
        				A20000000000000000000002 /* App.app */,
        				A20000000000000000000003 /* libPlugin.a */,
        				A20000000000000000000004 /* AppTests.xctest */,
        			);
        			name = Products;
        			sourceTree = "<group>";
        		};
        /* End PBXGroup section */

        /* Begin PBXNativeTarget section */
        		A50000000000000000000001 /* App */ = {
        			isa = PBXNativeTarget;
        			buildConfigurationList = A70000000000000000000002 /* Build configuration list for PBXNativeTarget "App" */;
        			buildPhases = (
        				A60000000000000000000001 /* Sources */,
        				A30000000000000000000001 /* Frameworks */,
        			);
        			buildRules = (
        			);
        			dependencies = (
        			);
        			name = App;
        			productName = App;
        			productReference = A20000000000000000000002 /* App.app */;
        			productType = "com.apple.product-type.application";
        		};
        		A50000000000000000000002 /* Plugin */ = {
        			isa = PBXNativeTarget;
        			buildConfigurationList = A70000000000000000000003 /* Build configuration list for PBXNativeTarget "Plugin" */;
        			buildPhases = (
        			);
        			buildRules = (
        			);
        			dependencies = (
        			);
        			name = Plugin;
        			productName = Plugin;
        			productReference = A20000000000000000000003 /* libPlugin.a */;
        			productType = "com.apple.product-type.library.static";
        		};
        		A50000000000000000000003 /* AppTests */ = {
        			isa = PBXNativeTarget;
        			buildConfigurationList = A70000000000000000000004 /* Build configuration list for PBXNativeTarget "AppTests" */;
        			buildPhases = (
        			);
        			buildRules = (
        			);
        			dependencies = (
        			);
        			name = AppTests;
        			productName = AppTests;
        			productReference = A20000000000000000000004 /* AppTests.xctest */;
        			productType = "com.apple.product-type.bundle.unit-test";
        		};
        /* End PBXNativeTarget section */

        /* Begin PBXProject section */
        		A00000000000000000000001 /* Project object */ = {
        			isa = PBXProject;
        			attributes = {
        				BuildIndependentTargetsInParallel = 1;
        				LastUpgradeCheck = 1600;
        			};
        			buildConfigurationList = A70000000000000000000001 /* Build configuration list for PBXProject "App" */;
        			developmentRegion = en;
        			hasScannedForEncodings = 0;
        			knownRegions = (
        				en,
        				Base,
        			);
        			mainGroup = A40000000000000000000001;
        			productRefGroup = A40000000000000000000002 /* Products */;
        			projectDirPath = "";
        			projectRoot = "";
        			targets = (
        				A50000000000000000000001 /* App */,
        				A50000000000000000000002 /* Plugin */,
        				A50000000000000000000003 /* AppTests */,
        			);
        		};
        /* End PBXProject section */

        /* Begin PBXSourcesBuildPhase section */
        		A60000000000000000000001 /* Sources */ = {
        			isa = PBXSourcesBuildPhase;
        			buildActionMask = 2147483647;
        			files = (
        				A10000000000000000000001 /* main.swift in Sources */,
        			);
        			runOnlyForDeploymentPostprocessing = 0;
        		};
        /* End PBXSourcesBuildPhase section */

        /* Begin XCBuildConfiguration section */
        		A80000000000000000000001 /* Debug */ = {
        			isa = XCBuildConfiguration;
        			buildSettings = {
        				SDKROOT = iphoneos;
        			};
        			name = Debug;
        		};
        		A80000000000000000000002 /* Release */ = {
        			isa = XCBuildConfiguration;
        			buildSettings = {
        				SDKROOT = iphoneos;
        			};
        			name = Release;
        		};
        		A80000000000000000000003 /* Debug */ = {
        			isa = XCBuildConfiguration;
        			buildSettings = {
        				PRODUCT_NAME = "$(TARGET_NAME)";
        			};
        			name = Debug;
        		};
        		A80000000000000000000004 /* Release */ = {
        			isa = XCBuildConfiguration;
        			buildSettings = {
        				PRODUCT_NAME = "$(TARGET_NAME)";
        			};
        			name = Release;
        		};
        		A80000000000000000000005 /* Debug */ = {
        			isa = XCBuildConfiguration;
        			buildSettings = {
        			};
        			name = Debug;
        		};
        		A80000000000000000000006 /* Release */ = {
        			isa = XCBuildConfiguration;
        			buildSettings = {
        			};
        			name = Release;
        		};
        		A80000000000000000000007 /* Debug */ = {
        			isa = XCBuildConfiguration;
        			buildSettings = {
        			};
        			name = Debug;
        		};
        		A80000000000000000000008 /* Release */ = {
        			isa = XCBuildConfiguration;
        			buildSettings = {
        			};
        			name = Release;
        		};
        /* End XCBuildConfiguration section */

        /* Begin XCConfigurationList section */
        		A70000000000000000000001 /* Build configuration list for PBXProject "App" */ = {
        			isa = XCConfigurationList;
        			buildConfigurations = (
        				A80000000000000000000001 /* Debug */,
        				A80000000000000000000002 /* Release */,
        			);
        			defaultConfigurationIsVisible = 0;
        			defaultConfigurationName = Release;
        		};
        		A70000000000000000000002 /* Build configuration list for PBXNativeTarget "App" */ = {
        			isa = XCConfigurationList;
        			buildConfigurations = (
        				A80000000000000000000003 /* Debug */,
        				A80000000000000000000004 /* Release */,
        			);
        			defaultConfigurationIsVisible = 0;
        			defaultConfigurationName = Release;
        		};
        		A70000000000000000000003 /* Build configuration list for PBXNativeTarget "Plugin" */ = {
        			isa = XCConfigurationList;
        			buildConfigurations = (
        				A80000000000000000000005 /* Debug */,
        				A80000000000000000000006 /* Release */,
        			);
        			defaultConfigurationIsVisible = 0;
        			defaultConfigurationName = Release;
        		};
        		A70000000000000000000004 /* Build configuration list for PBXNativeTarget "AppTests" */ = {
        			isa = XCConfigurationList;
        			buildConfigurations = (
        				A80000000000000000000007 /* Debug */,
        				A80000000000000000000008 /* Release */,
        			);
        			defaultConfigurationIsVisible = 0;
        			defaultConfigurationName = Release;
        		};
        /* End XCConfigurationList section */
        	};
        	rootObject = A00000000000000000000001 /* Project object */;
        }

        """

    /// A fresh directory with `App.xcodeproj` holding `project` and, optionally, a Podfile.
    public static func directory(podfile: String? = nil, files: [String: String] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpods-tests-" + UUID().uuidString, isDirectory: true)
        let projectDirectory = root.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try project.write(to: projectDirectory.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        if let podfile { try podfile.write(to: root.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8) }
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
}
