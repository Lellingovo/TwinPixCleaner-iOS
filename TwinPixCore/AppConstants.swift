import Foundation
import CoreGraphics
import os

/// Structured loggers for unified, subsystem-categorized Console.app logging.
public enum AppLogger {
    public static let scanner = Logger(subsystem: "com.wangjiale.TwinPixCleanerIOS", category: "Scanner")
    public static let quickLook = Logger(subsystem: "com.wangjiale.TwinPixCleanerIOS", category: "QuickLook")
    public static let general = Logger(subsystem: "com.wangjiale.TwinPixCleanerIOS", category: "General")
}

/// Centralized constants for TwinPixCleaner iOS.
public enum AppConstants {

    public enum Strings {
        public static let appName = "相册扫描"
        public static let appVersion = "1.0.0"
        public static let appBuild = "1"
        public static let aboutDescription = "在 iPhone 上查找重复与相似照片"
        public static let developerName = "Local"
        public static let websiteURL = ""
        public static let linkedinURL = websiteURL

        public static let newScan = "重新扫描"
        public static let cancelScan = "取消扫描"
        public static let selectFolder = "选择要扫描的文件夹"
        public static let dragDropPrompt = "或将文件夹拖放到此处"

        public static let scanningTitle = "正在扫描重复项"
        public static let scanComplete = "已完成 %d%%"

        public static let deleteSelected = "删除"
        public static let keepThis = "保留这张"
        public static let trash = "删除"
        public static let selectAllDuplicates = "全选重复项"
        public static let undoDelete = "撤销删除"

        public static let noDuplicatesFound = "未发现重复"
        public static let noDuplicatesDesc = "当前相册看起来很干净"

        public static let userGuide = "使用说明"

        public static let filesSkippedSuffix = "个项目已跳过（无法读取）"
    }

    public enum Icons {
        public static let appIcon = "photo.stack"
        public static let exactMatch = "rectangle.on.rectangle"
        public static let folderPlus = "folder.fill.badge.plus"
        public static let checkmarkCircle = "checkmark.circle"
        public static let photoCopies = "photo.on.rectangle.angled"
        public static let docText = "doc.text"
        public static let trash = "trash"
        public static let keepShield = "shield.checkered"
        public static let eyePreview = "eye.fill"
        public static let warningTriangle = "exclamationmark.triangle.fill"
    }

    public enum UI {
        public static let defaultCornerRadius: CGFloat = 16.0
        public static let cardCornerRadius: CGFloat = 20.0
    }

    public enum Scan {
        public static let similarityThresholdRev2: Float = 0.28
        public static let similarityThresholdRev2Screenshot: Float = 0.12
        public static let similarityThresholdRev1: Float = 8.0
        public static let similarityThresholdRev1Screenshot: Float = 3.0
        /// Max pixel size for PhotoKit decode before Vision feature print.
        public static let featurePrintMaxPixelSize: Int = 512
        /// Keep concurrency modest to avoid memory spikes / UI stalls.
        public static let maxConcurrentFeaturePrints: Int = 3

        public static func activeThreshold() -> Float {
            if #available(iOS 17.0, macOS 14.0, *) {
                return similarityThresholdRev2
            }
            return similarityThresholdRev1
        }

        public static func activeScreenshotThreshold() -> Float {
            if #available(iOS 17.0, macOS 14.0, *) {
                return similarityThresholdRev2Screenshot
            }
            return similarityThresholdRev1Screenshot
        }
    }
}
