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
  if mode=='Debug':config['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG $(inherited)';config['ENABLE_TESTABILITY']='YES'
  values.append(add(name+mode,'XCBuildConfiguration',name=mode,buildSettings=config))
 return add(name+'Configs','XCConfigurationList',buildConfigurations=values,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')

package=add('CorePackage','XCLocalSwiftPackageReference',relativePath='../mac')
core=add('CoreProduct','XCSwiftPackageProductDependency',package=package,productName='ScrivCore')
coretest=add('CoreTestProduct','XCSwiftPackageProductDependency',package=package,productName='ScrivCore')
corebuild=add('CoreLink','PBXBuildFile',productRef=core);coretestbuild=add('CoreTestLink','PBXBuildFile',productRef=coretest)
ui=add('UIKitSource','PBXFileSystemSynchronizedRootGroup',path='ScrivUIKit',sourceTree='<group>')
bridge=add('BridgeSource','PBXFileSystemSynchronizedRootGroup',path='MacRuntimeBridge',sourceTree='<group>')
tests=add('TestsSource','PBXFileSystemSynchronizedRootGroup',path='Tests',sourceTree='<group>')
legacy=[f'Services/{x}.swift' for x in ['WorkspaceStore','CloudClient','CloudClient+Generation','CodexController','InternetPeerMedia','LocalAudioEngine','ResourceBundle']]+['Views/ProjectHistoryPresentation.swift']
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
app=add('AppProduct','PBXFileReference',explicitFileType='wrapper.application',includeInIndex=0,path='ScrivUIKit.app',sourceTree='BUILT_PRODUCTS_DIR')
testproduct=add('TestProduct','PBXFileReference',explicitFileType='wrapper.cfbundle',includeInIndex=0,path='ScrivUIKitTests.xctest',sourceTree='BUILT_PRODUCTS_DIR')
products=add('Products','PBXGroup',name='Products',children=[app,testproduct],sourceTree='<group>')
main=add('MainGroup','PBXGroup',children=[ui,bridge,legacygroup,resources,tests,products],sourceTree='<group>')
settings={'CLANG_ENABLE_MODULES':'YES','SWIFT_VERSION':'5.0','SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'17.0','MACOSX_DEPLOYMENT_TARGET':'14.0','SUPPORTS_MACCATALYST':'YES','SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD':'NO','TARGETED_DEVICE_FAMILY':'2','CODE_SIGN_STYLE':'Automatic','ENABLE_APP_SANDBOX':'YES','ENABLE_HARDENED_RUNTIME':'YES','GENERATE_INFOPLIST_FILE':'NO','PRODUCT_NAME':'$(TARGET_NAME)','DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER':'NO'}
appsettings=dict(settings,PRODUCT_BUNDLE_IDENTIFIER='app.scriv.uikit',INFOPLIST_FILE='Info.plist',CODE_SIGN_ENTITLEMENTS='ScrivUIKit.entitlements',LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks','@executable_path/../Frameworks'])
sources=add('AppSources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=sourcefiles,runOnlyForDeploymentPostprocessing=0)
frameworks=add('AppFrameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[corebuild],runOnlyForDeploymentPostprocessing=0)
resphase=add('AppResources','PBXResourcesBuildPhase',buildActionMask=2147483647,files=resourcefiles,runOnlyForDeploymentPostprocessing=0)
apptarget=add('AppTarget','PBXNativeTarget',buildConfigurationList=buildconfigs('App',appsettings),buildPhases=[sources,frameworks,resphase],buildRules=[],dependencies=[],fileSystemSynchronizedGroups=[ui,bridge],name='ScrivUIKit',packageProductDependencies=[core],productName='ScrivUIKit',productReference=app,productType='com.apple.product-type.application')
proxy=add('TestProxy','PBXContainerItemProxy',containerPortal=ident('Project'),proxyType=1,remoteGlobalIDString=apptarget,remoteInfo='ScrivUIKit')
dependency=add('TestDependency','PBXTargetDependency',target=apptarget,targetProxy=proxy)
testsettings=dict(settings,PRODUCT_BUNDLE_IDENTIFIER='app.scriv.uikit.tests',GENERATE_INFOPLIST_FILE='YES',BUNDLE_LOADER='$(TEST_HOST)',TEST_TARGET_NAME='ScrivUIKit',TEST_HOST='$(BUILT_PRODUCTS_DIR)/ScrivUIKit.app/ScrivUIKit')
testsettings['TEST_HOST[sdk=macosx*]']='$(BUILT_PRODUCTS_DIR)/ScrivUIKit.app/Contents/MacOS/ScrivUIKit'
testtarget=add('TestTarget','PBXNativeTarget',buildConfigurationList=buildconfigs('Tests',testsettings),buildPhases=[add('TestSources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0),add('TestFrameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[coretestbuild],runOnlyForDeploymentPostprocessing=0),add('TestResources','PBXResourcesBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0)],buildRules=[],dependencies=[dependency],fileSystemSynchronizedGroups=[tests],name='ScrivUIKitTests',packageProductDependencies=[coretest],productName='ScrivUIKitTests',productReference=testproduct,productType='com.apple.product-type.bundle.unit-test')
projectid=add('Project','PBXProject',attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'2600','TargetAttributes':{apptarget:{'CreatedOnToolsVersion':'26.0'},testtarget:{'CreatedOnToolsVersion':'26.0','TestTargetID':apptarget}}},buildConfigurationList=buildconfigs('Project',{'SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES'}),compatibilityVersion='Xcode 16.0',developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','Base'],mainGroup=main,packageReferences=[package],preferredProjectObjectVersion=77,productRefGroup=products,projectDirPath='',projectRoot='',targets=[apptarget,testtarget])
def render(x,level=0):
 if isinstance(x,dict):return '{\n'+''.join('\t'*(level+1)+json.dumps(str(k))+' = '+render(v,level+1)+';\n' for k,v in x.items())+'\t'*level+'}'
 if isinstance(x,list):return '(\n'+''.join('\t'*(level+1)+render(v,level+1)+',\n' for v in x)+'\t'*level+')'
 return str(x) if isinstance(x,int) else json.dumps(x)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n'+render(dict(archiveVersion=1,classes={},objectVersion=77,objects=objects,rootObject=projectid))+'\n')
scheme=project/'xcshareddata/xcschemes/ScrivUIKit.xcscheme';scheme.parent.mkdir(parents=True,exist_ok=True)
ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{apptarget}" BuildableName="ScrivUIKit.app" BlueprintName="ScrivUIKit" ReferencedContainer="container:ScrivUIKit.xcodeproj"/>'
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
plist={'CFBundleDevelopmentRegion':'$(DEVELOPMENT_LANGUAGE)','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleInfoDictionaryVersion':'6.0','CFBundleName':'Scriv UIKit','CFBundleDisplayName':'Scriv','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0','CFBundleVersion':'1','LSApplicationCategoryType':'public.app-category.productivity','LSMinimumSystemVersion':'14.0','UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False},'UILaunchScreen':{},'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True},'CFBundleURLTypes':[{'CFBundleURLName':'Scriv project links','CFBundleURLSchemes':['scriv']}],'LSApplicationQueriesSchemes':['scriv-runtime-companion'],'UTExportedTypeDeclarations':[{'UTTypeIdentifier':'app.scriv.project','UTTypeDescription':'Scriv project','UTTypeConformsTo':['com.apple.package'],'UTTypeTagSpecification':{'public.filename-extension':['scriv']}}],'CFBundleDocumentTypes':[{'CFBundleTypeName':'Scriv project','LSItemContentTypes':['app.scriv.project'],'LSHandlerRank':'Owner','LSSupportsOpeningDocumentsInPlace':True}],'LSSupportsOpeningDocumentsInPlace':True,'ScrivCloudURL':'https://scriv-api.muddy-recipe-a722.workers.dev'}
(folder/'Info.plist').write_bytes(plistlib.dumps(plist,sort_keys=False))
(folder/'ScrivUIKit.entitlements').write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True,'com.apple.security.files.user-selected.read-write':True},sort_keys=False))
print('Generated UIKit-only app/test targets; legacy UI and macOS Process helper excluded.')
