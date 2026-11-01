#!/usr/bin/env python3
"""Deterministic Xcode project; UIKit and test folders are synchronized, legacy UI excluded."""
from pathlib import Path
import hashlib, json, plistlib
root=Path(__file__).resolve().parent.parent
folder=root/'apps/catalyst'; project=folder/'ScrivUIKit.xcodeproj'; project.mkdir(parents=True,exist_ok=True)
objects={}
def ident(name): return hashlib.sha1(('ScrivUIKit:'+name).encode()).hexdigest()[:24].upper()
def add(logical_id,isa,**values):
 key=ident(logical_id);objects[key]=dict(isa=isa,**values);return key

def buildconfigs(name,settings):
 values=[]
 for mode in ['Debug','Release']:
  config=dict(settings);config['SWIFT_OPTIMIZATION_LEVEL']='-Onone' if mode=='Debug' else '-O';config['DEBUG_INFORMATION_FORMAT']='dwarf' if mode=='Debug' else 'dwarf-with-dsym'
  # Match SwiftPM's Debug active-architecture build; Release stays universal.
  config['ONLY_ACTIVE_ARCH']='YES' if mode=='Debug' else 'NO'
  if mode=='Debug':config['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG '+config.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS','$(inherited)');config['ENABLE_TESTABILITY']='YES'
  values.append(add(name+mode,'XCBuildConfiguration',name=mode,buildSettings=config))
 return add(name+'Configs','XCConfigurationList',buildConfigurations=values,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')

package=add('CorePackage','XCLocalSwiftPackageReference',relativePath='../mac')
core=add('CoreProduct','XCSwiftPackageProductDependency',package=package,productName='ScrivCore')
coretest=add('CoreTestProduct','XCSwiftPackageProductDependency',package=package,productName='ScrivCore')
corebuild=add('CoreLink','PBXBuildFile',productRef=core);coretestbuild=add('CoreTestLink','PBXBuildFile',productRef=coretest)
ui=add('UIKitSource','PBXFileSystemSynchronizedRootGroup',path='ScrivUIKit',sourceTree='<group>')
bridge=add('BridgeSource','PBXFileSystemSynchronizedRootGroup',path='MacRuntimeBridge',sourceTree='<group>')
tests=add('TestsSource','PBXFileSystemSynchronizedRootGroup',path='Tests',sourceTree='<group>')
legacy=[f'Services/{x}.swift' for x in ['WorkspaceStore','CloudClient','CloudClient+Generation','CodexController','CharacterAnalysisController','InternetPeerMedia','LocalAudioEngine','ResourceBundle']]+['Views/ProjectHistoryPresentation.swift']
sourcefiles=[];legacyrefs=[]
for path in legacy:
 ref=add('Legacy:'+path,'PBXFileReference',lastKnownFileType='sourcecode.swift',path='../mac/Sources/ScrivApp/'+path,sourceTree='SOURCE_ROOT')
 legacyrefs.append(ref);sourcefiles.append(add('Source:'+path,'PBXBuildFile',fileRef=ref))
legacygroup=add('SharedServices','PBXGroup',name='Shared domain services (no legacy UI)',children=legacyrefs,sourceTree='<group>')
resourcefiles=[];resourcerefs=[]
for path in ['PeerTransfer','SampleImages']:
 ref=add('Resource:'+path,'PBXFileReference',lastKnownFileType='folder',path='../mac/Sources/ScrivApp/Resources/'+path,sourceTree='SOURCE_ROOT')
 resourcerefs.append(ref);resourcefiles.append(add('ResourceBuild:'+path,'PBXBuildFile',fileRef=ref))
resources=add('Resources','PBXGroup',name='Shared resources',children=resourcerefs,sourceTree='<group>')
app=add('AppProduct','PBXFileReference',explicitFileType='wrapper.application',includeInIndex=0,path='Scriv.app',sourceTree='BUILT_PRODUCTS_DIR')
testproduct=add('TestProduct','PBXFileReference',explicitFileType='wrapper.cfbundle',includeInIndex=0,path='ScrivUIKitTests.xctest',sourceTree='BUILT_PRODUCTS_DIR')
products=add('Products','PBXGroup',name='Products',children=[app,testproduct],sourceTree='<group>')
main=add('MainGroup','PBXGroup',children=[ui,bridge,legacygroup,resources,tests,products],sourceTree='<group>')
settings={'CLANG_ENABLE_MODULES':'YES','SWIFT_VERSION':'5.0','SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'17.0','MACOSX_DEPLOYMENT_TARGET':'14.0','SUPPORTS_MACCATALYST':'YES','SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD':'NO','TARGETED_DEVICE_FAMILY':'2','CODE_SIGN_STYLE':'Automatic','ENABLE_APP_SANDBOX':'YES','ENABLE_HARDENED_RUNTIME':'YES','GENERATE_INFOPLIST_FILE':'NO','PRODUCT_NAME':'$(TARGET_NAME)','DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER':'NO'}
appsettings=dict(settings,PRODUCT_NAME='Scriv',PRODUCT_MODULE_NAME='ScrivUIKit',MARKETING_VERSION='1.0',CURRENT_PROJECT_VERSION='1',SCRIV_UPDATE_CHANNEL='stable',SCRIV_UPDATE_FEED_URL='https://scriv-updates.why-not.work/appcast.xml',SWIFT_OBJC_BRIDGING_HEADER='UpdateBridge/ScrivUpdateBridge.h',ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon',PRODUCT_BUNDLE_IDENTIFIER='app.scriv.uikit',INFOPLIST_FILE='Info.plist',CODE_SIGN_ENTITLEMENTS='ScrivUIKit.entitlements',LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks','@executable_path/../Frameworks'])
sources=add('AppSources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=sourcefiles,runOnlyForDeploymentPostprocessing=0)
frameworks=add('AppFrameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[corebuild],runOnlyForDeploymentPostprocessing=0)
resphase=add('AppResources','PBXResourcesBuildPhase',buildActionMask=2147483647,files=resourcefiles,runOnlyForDeploymentPostprocessing=0)
apptarget=add('AppTarget','PBXNativeTarget',buildConfigurationList=buildconfigs('App',appsettings),buildPhases=[sources,frameworks,resphase],buildRules=[],dependencies=[],fileSystemSynchronizedGroups=[ui,bridge],name='ScrivUIKit',packageProductDependencies=[core],productName='ScrivUIKit',productReference=app,productType='com.apple.product-type.application')
proxy=add('TestProxy','PBXContainerItemProxy',containerPortal=ident('Project'),proxyType=1,remoteGlobalIDString=apptarget,remoteInfo='ScrivUIKit')
dependency=add('TestDependency','PBXTargetDependency',target=apptarget,targetProxy=proxy)
testsettings=dict(settings,PRODUCT_BUNDLE_IDENTIFIER='app.scriv.uikit.tests',GENERATE_INFOPLIST_FILE='YES',BUNDLE_LOADER='$(TEST_HOST)',TEST_TARGET_NAME='ScrivUIKit',TEST_HOST='$(BUILT_PRODUCTS_DIR)/Scriv.app/Scriv')
testsettings['TEST_HOST[sdk=macosx*]']='$(BUILT_PRODUCTS_DIR)/Scriv.app/Contents/MacOS/Scriv'
testtarget=add('TestTarget','PBXNativeTarget',buildConfigurationList=buildconfigs('Tests',testsettings),buildPhases=[add('TestSources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0),add('TestFrameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[coretestbuild],runOnlyForDeploymentPostprocessing=0),add('TestResources','PBXResourcesBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0)],buildRules=[],dependencies=[dependency],fileSystemSynchronizedGroups=[tests],name='ScrivUIKitTests',packageProductDependencies=[coretest],productName='ScrivUIKitTests',productReference=testproduct,productType='com.apple.product-type.bundle.unit-test')
# Sparkle's supported Catalyst boundary is an AppKit bundle loaded at runtime.
sparklepackage=add('SparklePackage','XCRemoteSwiftPackageReference',repositoryURL='https://github.com/sparkle-project/Sparkle',requirement={'kind':'exactVersion','version':'2.10.1'})
sparkle=add('SparkleProduct','XCSwiftPackageProductDependency',package=sparklepackage,productName='Sparkle')
pluginref=add('UpdatePluginProduct','PBXFileReference',explicitFileType='wrapper.cfbundle',includeInIndex=0,path='ScrivUpdatePlugin.bundle',sourceTree='BUILT_PRODUCTS_DIR')
pluginsource=add('UpdatePluginSource','PBXFileReference',lastKnownFileType='sourcecode.c.objc',path='UpdatePlugin/ScrivSparklePlugin.m',sourceTree='SOURCE_ROOT')
objects[main]['children'].append(pluginsource); objects[products]['children'].append(pluginref)
pluginsettings={'SDKROOT':'macosx','SUPPORTED_PLATFORMS':'macosx','SUPPORTS_MACCATALYST':'NO','MACOSX_DEPLOYMENT_TARGET':'14.0','PRODUCT_NAME':'ScrivUpdatePlugin','PRODUCT_BUNDLE_IDENTIFIER':'app.scriv.uikit.updates','INFOPLIST_FILE':'UpdatePlugin/Info.plist','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','CODE_SIGN_STYLE':'Automatic','ENABLE_HARDENED_RUNTIME':'YES','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@loader_path/../Frameworks','@loader_path/../../../Frameworks'],'SKIP_INSTALL':'YES'}
pluginframeworks=add('UpdatePluginFrameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[add('SparkleLink','PBXBuildFile',productRef=sparkle)],runOnlyForDeploymentPostprocessing=0)
plugintarget=add('UpdatePluginTarget','PBXNativeTarget',buildConfigurationList=buildconfigs('UpdatePlugin',pluginsettings),buildPhases=[add('UpdatePluginSources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=[add('UpdatePluginCompile','PBXBuildFile',fileRef=pluginsource)],runOnlyForDeploymentPostprocessing=0),pluginframeworks],buildRules=[],dependencies=[],name='ScrivUpdatePlugin',packageProductDependencies=[sparkle],productName='ScrivUpdatePlugin',productReference=pluginref,productType='com.apple.product-type.bundle')
pluginproxy=add('UpdatePluginProxy','PBXContainerItemProxy',containerPortal=ident('Project'),proxyType=1,remoteGlobalIDString=plugintarget,remoteInfo='ScrivUpdatePlugin')
objects[apptarget]['dependencies'].append(add('UpdatePluginDependency','PBXTargetDependency',target=plugintarget,targetProxy=pluginproxy))
objects[apptarget]['buildPhases'].append(add('EmbedUpdatePlugin','PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='',dstSubfolderSpec=13,files=[add('UpdatePluginEmbed','PBXBuildFile',fileRef=pluginref,settings={'ATTRIBUTES':['CodeSignOnCopy','RemoveHeadersOnCopy']})],name='Embed native update plug-in',runOnlyForDeploymentPostprocessing=0))
# Both macOS-only runtime bootstrap and Sparkle share a native ABI adapter.
# Catalyst itself never compiles named XPC, Security code identity, or Process.
# A mixed Catalyst/macOS archive cannot reuse the same Swift package product:
# Xcode stages both platform variants at UninstalledProducts/macosx/ScrivCore.o.
# Compile the SAME canonical Core sources into each existing native module
# instead. No source copies, new framework, output-path override or trust change.
# Only Foundation/Data crosses the adapter ABI; Core Swift types never cross it.
nativecorerefs=[]
for path in sorted((root/'apps/mac/Sources/ScrivCore').rglob('*.swift')):
 relative=path.relative_to(root/'apps/mac/Sources/ScrivCore').as_posix()
 nativecorerefs.append(add('NativeCore:'+relative,'PBXFileReference',lastKnownFileType='sourcecode.swift',path='../mac/Sources/ScrivCore/'+relative,sourceTree='SOURCE_ROOT'))
if not nativecorerefs: raise RuntimeError('Canonical ScrivCore sources are missing')
objects[main]['children'].append(add('NativeCoreSources','PBXGroup',name='Canonical Core sources (native target membership)',children=nativecorerefs,sourceTree='<group>'))
def native_core_sources(target):
 return [add('NativeCoreCompile:'+target+':'+ref,'PBXBuildFile',fileRef=ref) for ref in nativecorerefs]
objects[ident('UpdatePluginSources')]['files'].extend(native_core_sources('Adapter'))
for path in ['../runtime-bridge/Integration/ScrivRuntimeBootstrapClient.swift','RuntimeAdapter/ScrivRuntimeBootstrapAdapter.swift']:
 ref=add('Adapter:'+path,'PBXFileReference',lastKnownFileType='sourcecode.swift',path=path,sourceTree='SOURCE_ROOT')
 objects[main]['children'].append(ref)
 objects[ident('UpdatePluginSources')]['files'].append(add('AdapterCompile:'+path,'PBXBuildFile',fileRef=ref))
for mode in ['Debug','Release']:
 objects[ident('UpdatePlugin'+mode)]['buildSettings'].update({'SWIFT_VERSION':'5.0','SWIFT_OBJC_BRIDGING_HEADER':'UpdateBridge/ScrivUpdateBridge.h','PRODUCT_MODULE_NAME':'ScrivNativeAdapter','DEFINES_MODULE':'YES','SWIFT_ACTIVE_COMPILATION_CONDITIONS':('DEBUG ' if mode=='Debug' else '')+'$(inherited) SCRIV_EMBEDDED_NATIVE_CORE'})
# Explicit host-runtime authority: this private, on-demand service has the same
# authority as the existing standalone companion. Parent sandbox is unchanged.
# No shared Keychain groups, filesystem exceptions, daemon, or auto-launch grant.
xpcref=add('BootstrapProduct','PBXFileReference',explicitFileType='wrapper.xpc-service',includeInIndex=0,path='com.scriv.runtime-companion.bootstrap.xpc',sourceTree='BUILT_PRODUCTS_DIR')
objects[products]['children'].append(xpcref)
xpcsources=native_core_sources('Bootstrap')
for path in ['main.swift','RuntimeBootstrapXPC.swift']:
 ref=add('Bootstrap:'+path,'PBXFileReference',lastKnownFileType='sourcecode.swift',path='../runtime-bridge/Sources/ScrivRuntimeCompanion/'+path,sourceTree='SOURCE_ROOT')
 objects[main]['children'].append(ref);xpcsources.append(add('BootstrapCompile:'+path,'PBXBuildFile',fileRef=ref))
xpcsettings={'SDKROOT':'macosx','SUPPORTED_PLATFORMS':'macosx','SUPPORTS_MACCATALYST':'NO','MACOSX_DEPLOYMENT_TARGET':'14.0','PRODUCT_NAME':'com.scriv.runtime-companion.bootstrap','EXECUTABLE_NAME':'ScrivRuntimeCompanion','PRODUCT_MODULE_NAME':'ScrivRuntimeCompanion','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'$(inherited) SCRIV_EMBEDDED_NATIVE_CORE','PRODUCT_BUNDLE_IDENTIFIER':'com.scriv.runtime-companion.bootstrap','INFOPLIST_FILE':'../runtime-bridge/Bootstrap-Info.plist','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES','CODE_SIGN_STYLE':'Automatic','ENABLE_HARDENED_RUNTIME':'YES','ENABLE_APP_SANDBOX':'NO','SKIP_INSTALL':'YES'}
xpctarget=add('BootstrapTarget','PBXNativeTarget',buildConfigurationList=buildconfigs('Bootstrap',xpcsettings),buildPhases=[add('BootstrapSources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=xpcsources,runOnlyForDeploymentPostprocessing=0),add('BootstrapFrameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0)],buildRules=[],dependencies=[],name='ScrivRuntimeBootstrap',packageProductDependencies=[],productName='com.scriv.runtime-companion.bootstrap',productReference=xpcref,productType='com.apple.product-type.xpc-service')
xpcproxy=add('BootstrapProxy','PBXContainerItemProxy',containerPortal=ident('Project'),proxyType=1,remoteGlobalIDString=xpctarget,remoteInfo='ScrivRuntimeBootstrap')
objects[apptarget]['dependencies'].append(add('BootstrapDependency','PBXTargetDependency',target=xpctarget,targetProxy=xpcproxy))
objects[apptarget]['buildPhases'].append(add('EmbedBootstrap','PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='$(CONTENTS_FOLDER_PATH)/XPCServices',dstSubfolderSpec=16,files=[add('BootstrapEmbed','PBXBuildFile',fileRef=xpcref,settings={'ATTRIBUTES':['CodeSignOnCopy','RemoveHeadersOnCopy']})],name='Embed user-authorized local runtime service',runOnlyForDeploymentPostprocessing=0))
projectid=add('Project','PBXProject',attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'2600','TargetAttributes':{apptarget:{'CreatedOnToolsVersion':'26.0'},testtarget:{'CreatedOnToolsVersion':'26.0','TestTargetID':apptarget}}},buildConfigurationList=buildconfigs('Project',{'SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES'}),compatibilityVersion='Xcode 16.0',developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','Base'],mainGroup=main,packageReferences=[package,sparklepackage],preferredProjectObjectVersion=77,productRefGroup=products,projectDirPath='',projectRoot='',targets=[apptarget,testtarget,plugintarget,xpctarget])
def render(x,level=0):
 if isinstance(x,dict):return '{\n'+''.join('\t'*(level+1)+json.dumps(str(k))+' = '+render(v,level+1)+';\n' for k,v in x.items())+'\t'*level+'}'
 if isinstance(x,list):return '(\n'+''.join('\t'*(level+1)+render(v,level+1)+',\n' for v in x)+'\t'*level+')'
 return str(x) if isinstance(x,int) else json.dumps(x)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n'+render(dict(archiveVersion=1,classes={},objectVersion=77,objects=objects,rootObject=projectid))+'\n')
scheme=project/'xcshareddata/xcschemes/ScrivUIKit.xcscheme';scheme.parent.mkdir(parents=True,exist_ok=True)
ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{apptarget}" BuildableName="Scriv.app" BlueprintName="ScrivUIKit" ReferencedContainer="container:ScrivUIKit.xcodeproj"/>'
tref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{testtarget}" BuildableName="ScrivUIKitTests.xctest" BlueprintName="ScrivUIKitTests" ReferencedContainer="container:ScrivUIKit.xcodeproj"/>'
scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO"><Testables><TestableReference skipped="NO">{tref}</TestableReference></Testables><CommandLineArguments><CommandLineArgument argument="--screenshots" isEnabled="YES"/></CommandLineArguments></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
plist={'CFBundleDevelopmentRegion':'$(DEVELOPMENT_LANGUAGE)','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleInfoDictionaryVersion':'6.0','CFBundleName':'Scriv UIKit','CFBundleDisplayName':'Scriv','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0','CFBundleVersion':'1','LSApplicationCategoryType':'public.app-category.productivity','LSMinimumSystemVersion':'14.0','UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False},'UILaunchScreen':{},'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True},'CFBundleURLTypes':[{'CFBundleURLName':'Scriv project links','CFBundleURLSchemes':['scriv']}],'LSApplicationQueriesSchemes':['scriv-runtime-companion'],'UTExportedTypeDeclarations':[{'UTTypeIdentifier':'app.scriv.project','UTTypeDescription':'Scriv project','UTTypeConformsTo':['com.apple.package'],'UTTypeTagSpecification':{'public.filename-extension':['scriv']}}],'CFBundleDocumentTypes':[{'CFBundleTypeName':'Scriv project','CFBundleTypeRole':'Editor','LSItemContentTypes':['app.scriv.project'],'LSHandlerRank':'Owner','LSSupportsOpeningDocumentsInPlace':True}],'LSSupportsOpeningDocumentsInPlace':True,'ScrivCloudURL':'https://scriv-api.muddy-recipe-a722.workers.dev'}
plist.update({'CFBundleName':'Scriv','CFBundleShortVersionString':'$(MARKETING_VERSION)','CFBundleVersion':'$(CURRENT_PROJECT_VERSION)','SUFeedURL':'$(SCRIV_UPDATE_FEED_URL)','ScrivUpdateChannel':'$(SCRIV_UPDATE_CHANNEL)','SUPublicEDKey':'$(SCRIV_UPDATE_PUBLIC_KEY)','ScrivUpdateTeamIdentifier':'$(DEVELOPMENT_TEAM)','SUEnableAutomaticChecks':False,'SUAutomaticallyUpdate':False,'SUAllowsAutomaticUpdates':False,'SUEnableSystemProfiling':False,'SUSendProfileInfo':False,'SURequireSignedFeed':True,'SUVerifyUpdateBeforeExtraction':True,'SUSignedFeedFailureExpirationInterval':0,'SUEnableInstallerLauncherService':True,'SUEnableDownloaderService':False,'SUShowReleaseNotes':True})
(folder/'Info.plist').write_bytes(plistlib.dumps(plist,sort_keys=False))
(folder/'ScrivUIKit.entitlements').write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True,'com.apple.security.files.user-selected.read-write':True,'com.apple.security.temporary-exception.mach-lookup.global-name':['$(PRODUCT_BUNDLE_IDENTIFIER)-spks','$(PRODUCT_BUNDLE_IDENTIFIER)-spki']},sort_keys=False))
print('Generated UIKit app/tests, native adapter, and on-demand signed runtime XPC; legacy UI remains excluded.')
