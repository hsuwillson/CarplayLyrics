#!/usr/bin/env python3
"""產生 CarLyrics.xcodeproj（不需要 XcodeGen / Homebrew）。

使用 Xcode 16+ 的「資料夾同步群組」(PBXFileSystemSynchronizedRootGroup)：
CarLyrics/、CarLyricsWidget/、Shared/ 裡新增的 .swift 檔會自動加入 target，
所以只有在改 target / build settings 時才需要重跑：

    python3 tools/make_xcodeproj.py
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ── 可調整的設定 ──────────────────────────────────────────
BUNDLE_ID = "com.willsonhsu.CarLyrics"
WIDGET_BUNDLE_ID = BUNDLE_ID + ".Widget"
DEPLOYMENT_TARGET = "26.0"
DEVELOPMENT_TEAM = os.environ.get("DEVELOPMENT_TEAM", "")  # 可用環境變數帶入 Team ID
# ─────────────────────────────────────────────────────────


def oid(name: str) -> str:
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()


def q(v: str) -> str:
    safe = all(c.isalnum() or c in "._/$" for c in v) and v != ""
    return v if safe else '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'


def fmt(v, ind=2) -> str:
    pad = "\t" * ind
    if isinstance(v, dict):
        inner = "".join(f"{pad}\t{q(k)} = {fmt(x, ind + 1)};\n" for k, x in v.items())
        return "{\n" + inner + pad + "}"
    if isinstance(v, list):
        inner = "".join(f"{pad}\t{fmt(x, ind + 1)},\n" for x in v)
        return "(\n" + inner + pad + ")"
    return q(str(v))


objs = {}


def add(key, isa, **props):
    i = oid(key)
    objs[i] = {"isa": isa, **props}
    return i


# 同步資料夾
g_app = add("grp.app", "PBXFileSystemSynchronizedRootGroup", path="CarLyrics", sourceTree="<group>")
g_widget = add("grp.widget", "PBXFileSystemSynchronizedRootGroup", path="CarLyricsWidget", sourceTree="<group>")
g_shared = add("grp.shared", "PBXFileSystemSynchronizedRootGroup", path="Shared", sourceTree="<group>")
# Core：純邏輯（LRC 解析、同步計算），App 與單元測試共用
g_core = add("grp.core", "PBXFileSystemSynchronizedRootGroup", path="Core", sourceTree="<group>")
g_tests = add("grp.tests", "PBXFileSystemSynchronizedRootGroup", path="CarLyricsTests", sourceTree="<group>")

# Config 檔（只做顯示，不加入 target）
cfg_files = ["CarLyrics-Info.plist", "CarLyrics.entitlements",
             "CarLyricsWidget-Info.plist", "CarLyricsWidget.entitlements"]
cfg_refs = []
for f in cfg_files:
    ftype = "text.plist.xml" if f.endswith(".plist") else "text.plist.entitlements"
    cfg_refs.append(add("cfg." + f, "PBXFileReference", lastKnownFileType=ftype, path=f, sourceTree="<group>"))
g_config = add("grp.config", "PBXGroup", children=cfg_refs, path="Config", sourceTree="<group>")

# 產物
p_app = add("prod.app", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex="0",
            path="CarLyrics.app", sourceTree="BUILT_PRODUCTS_DIR")
p_widget = add("prod.widget", "PBXFileReference", explicitFileType="wrapper.app-extension", includeInIndex="0",
               path="CarLyricsWidget.appex", sourceTree="BUILT_PRODUCTS_DIR")
p_tests = add("prod.tests", "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex="0",
              path="CarLyricsTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
g_products = add("grp.products", "PBXGroup", children=[p_app, p_widget, p_tests], name="Products", sourceTree="<group>")

g_main = add("grp.main", "PBXGroup", children=[g_app, g_widget, g_shared, g_core, g_tests, g_config, g_products], sourceTree="<group>")


def phases(prefix):
    return (add(prefix + ".sources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0"),
            add(prefix + ".frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0"),
            add(prefix + ".resources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0"))


common = {
    "CODE_SIGN_STYLE": "Automatic",
    "DEVELOPMENT_TEAM": DEVELOPMENT_TEAM,
    "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
    "SDKROOT": "iphoneos",
    "SWIFT_VERSION": "5.0",
    "TARGETED_DEVICE_FAMILY": "1",
    "MARKETING_VERSION": "0.1.0",
    "CURRENT_PROJECT_VERSION": "1",
    "GENERATE_INFOPLIST_FILE": "YES",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
}


def target_configs(name, extra):
    ids = []
    for c in ("Debug", "Release"):
        s = dict(common)
        s.update(extra)
        ids.append(add(f"cfg.{name}.{c}", "XCBuildConfiguration", buildSettings=s, name=c))
    return add(f"cfglist.{name}", "XCConfigurationList", buildConfigurations=ids,
               defaultConfigurationIsVisible="0", defaultConfigurationName="Release")


# Widget Extension target
w_src, w_fw, w_res = phases("widget")
w_list = target_configs("widget", {
    "PRODUCT_BUNDLE_IDENTIFIER": WIDGET_BUNDLE_ID,
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "INFOPLIST_FILE": "Config/CarLyricsWidget-Info.plist",
    "INFOPLIST_KEY_CFBundleDisplayName": "CarLyrics Widget",
    "CODE_SIGN_ENTITLEMENTS": "Config/CarLyricsWidget.entitlements",
    "SKIP_INSTALL": "YES",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
})
t_widget = add("target.widget", "PBXNativeTarget", buildConfigurationList=w_list,
               buildPhases=[w_src, w_fw, w_res], buildRules=[], dependencies=[],
               fileSystemSynchronizedGroups=[g_widget, g_shared],
               name="CarLyricsWidget", productName="CarLyricsWidget",
               productReference=p_widget, productType="com.apple.product-type.app-extension")

# App target
proxy = add("proxy.widget", "PBXContainerItemProxy", containerPortal=oid("project"), proxyType="1",
            remoteGlobalIDString=t_widget, remoteInfo="CarLyricsWidget")
dep = add("dep.widget", "PBXTargetDependency", target=t_widget, targetProxy=proxy)
embed_file = add("bf.embed.widget", "PBXBuildFile", fileRef=p_widget,
                 settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
embed = add("app.embed", "PBXCopyFilesBuildPhase", buildActionMask="2147483647", dstPath="",
            dstSubfolderSpec="13", files=[embed_file], name="Embed Foundation Extensions",
            runOnlyForDeploymentPostprocessing="0")
a_src, a_fw, a_res = phases("app")
a_list = target_configs("app", {
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "INFOPLIST_FILE": "Config/CarLyrics-Info.plist",
    "INFOPLIST_KEY_CFBundleDisplayName": "CarLyrics",
    "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations": "UIInterfaceOrientationPortrait",
    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
    "CODE_SIGN_ENTITLEMENTS": "Config/CarLyrics.entitlements",
    "ENABLE_PREVIEWS": "YES",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
})
t_app = add("target.app", "PBXNativeTarget", buildConfigurationList=a_list,
            buildPhases=[a_src, a_fw, a_res, embed], buildRules=[], dependencies=[dep],
            fileSystemSynchronizedGroups=[g_app, g_shared, g_core],
            name="CarLyrics", productName="CarLyrics",
            productReference=p_app, productType="com.apple.product-type.application")

# Unit test target（不需要 host App，直接編譯 Core/ 的原始碼，在模擬器上跑）
x_src, x_fw, x_res = phases("tests")
x_list = target_configs("tests", {
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID + ".Tests",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "CODE_SIGNING_ALLOWED": "NO",
})
t_tests = add("target.tests", "PBXNativeTarget", buildConfigurationList=x_list,
              buildPhases=[x_src, x_fw, x_res], buildRules=[], dependencies=[],
              fileSystemSynchronizedGroups=[g_core, g_tests],
              name="CarLyricsTests", productName="CarLyricsTests",
              productReference=p_tests, productType="com.apple.product-type.bundle.unit-test")

# Project
proj_settings_common = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
    "SDKROOT": "iphoneos",
}
p_debug = add("cfg.proj.Debug", "XCBuildConfiguration", name="Debug", buildSettings={
    **proj_settings_common,
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
})
p_release = add("cfg.proj.Release", "XCBuildConfiguration", name="Release", buildSettings={
    **proj_settings_common,
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "VALIDATE_PRODUCT": "YES",
})
p_list = add("cfglist.proj", "XCConfigurationList", buildConfigurations=[p_debug, p_release],
             defaultConfigurationIsVisible="0", defaultConfigurationName="Release")

objs[oid("project")] = {
    "isa": "PBXProject",
    "attributes": {
        "BuildIndependentTargetsInParallel": "1",
        "LastSwiftUpdateCheck": "2600",
        "LastUpgradeCheck": "2600",
        "TargetAttributes": {t_app: {"CreatedOnToolsVersion": "26.0"},
                             t_widget: {"CreatedOnToolsVersion": "26.0"},
                             t_tests: {"CreatedOnToolsVersion": "26.0"}},
    },
    "buildConfigurationList": p_list,
    "developmentRegion": "en",
    "hasScannedForEncodings": "0",
    "knownRegions": ["en", "Base", "zh-Hant"],
    "mainGroup": g_main,
    "minimizedProjectReferenceProxies": "1",
    "preferredProjectObjectVersion": "77",
    "productRefGroup": g_products,
    "projectDirPath": "",
    "projectRoot": "",
    "targets": [t_app, t_widget, t_tests],
}

out = ["// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n\tobjects = {\n"]
for i in sorted(objs):
    out.append(f"\t\t{i} = {fmt(objs[i], 2)};\n")
out.append(f"\t}};\n\trootObject = {oid('project')};\n}}\n")

proj_dir = os.path.join(ROOT, "CarLyrics.xcodeproj")
os.makedirs(proj_dir, exist_ok=True)
with open(os.path.join(proj_dir, "project.pbxproj"), "w") as fh:
    fh.write("".join(out))

# 共享 scheme，讓 Xcode 一打開就能選 CarLyrics 執行
scheme_dir = os.path.join(proj_dir, "xcshareddata", "xcschemes")
os.makedirs(scheme_dir, exist_ok=True)
ref = f'''<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{t_app}" BuildableName = "CarLyrics.app" BlueprintName = "CarLyrics" ReferencedContainer = "container:CarLyrics.xcodeproj">
         </BuildableReference>'''
test_ref = f'''<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{t_tests}" BuildableName = "CarLyricsTests.xctest" BlueprintName = "CarLyricsTests" ReferencedContainer = "container:CarLyrics.xcodeproj">
            </BuildableReference>'''
with open(os.path.join(scheme_dir, "CarLyrics.xcscheme"), "w") as fh:
    fh.write(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            {test_ref}
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
''')
print("已產生", proj_dir)
