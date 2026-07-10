BASEDIR = $(shell pwd)
BUILD_DIR = $(BASEDIR)/build
INSTALL_DIR = $(BUILD_DIR)/install
PROJECT = $(BASEDIR)/APP.xcodeproj
SCHEME = APP
CONFIGURATION = Release
SDK = iphoneos
DERIVED_DATA_PATH = $(BUILD_DIR)

all: ipa

# 依赖关系
ipa: $(PROJECT)
	@echo "开始构建..."
	mkdir -p ./build
	@echo "执行xcodebuild..."
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -sdk $(SDK) -derivedDataPath $(DERIVED_DATA_PATH) CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
	@echo "检查构建结果..."
	ls -la ./build/Build/Products/$(CONFIGURATION)-$(SDK)/
	@echo "清理旧文件..."
	rm -rf ./build/APP.ipa
	rm -rf ./build/Payload
	mkdir -p ./build/Payload
	@echo "复制应用文件..."
	cp -rv ./build/Build/Products/$(CONFIGURATION)-$(SDK)/APP.app ./build/Payload
	@echo "打包IPA..."
	cd ./build && zip -r APP.ipa Payload
	@echo "移动IPA文件..."
	mv ./build/APP.ipa ./
	@echo "构建完成！"

# 强制重新构建
force: clean ipa

clean:
	rm -rf ./build
	rm -rf ./APP.ipa

.PHONY: all ipa clean force
