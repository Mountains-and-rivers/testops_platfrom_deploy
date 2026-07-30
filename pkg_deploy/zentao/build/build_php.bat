@echo off
REM ============================================================
REM Windows PHP 8.1 + Apache 2.4 运行环境安装脚本
REM 禅道开源版开发环境一键部署
REM 用法: build_php.bat               默认使用内置版本号
REM       build_php.bat 8.1.27 2.4.62 指定 PHP 和 Apache 版本
REM ============================================================
setlocal enabledelayedexpansion

REM ---- 可配置参数 ----
set "PHP_VERSION=%1"
if "%PHP_VERSION%"=="" set "PHP_VERSION=8.1.27"
set "HTTPD_VERSION=%2"
if "%HTTPD_VERSION%"=="" set "HTTPD_VERSION=2.4.62"

REM VC 版本映射（PHP 8.1 使用 VS16 / VC 2019）
set "VC_VERSION=vs16"
set "VC_REDIST_URL=https://aka.ms/vs/17/release/vc_redist.x64.exe"

REM ---- 路径配置 ----
set "INSTALL_ROOT=C:\"
set "PHP_DIR=%INSTALL_ROOT%php"
set "HTTPD_DIR=%INSTALL_ROOT%Apache24"
set "ZENTAO_DIR=%INSTALL_ROOT%zentaopms"
set "SCRIPT_DIR=%~dp0"
set "TEMP_DIR=%TEMP%\php-build"
set "LOG_FILE=%SCRIPT_DIR%build_php.log"

REM ---- 颜色宏（Windows 10+ 支持 ANSI 转义）----
for /f "tokens=2 delims=[]" %%a in ('ver') do set "WIN_VER=%%a"
set "GREEN=[92m" & set "RED=[91m" & set "YELLOW=[93m" & set "CYAN=[96m" & set "NC=[0m"
for /f %%a in ('echo prompt $E ^| cmd') do set "ESC=%%a"
set "GREEN=%ESC%%GREEN%" & set "RED=%ESC%%RED%" & set "YELLOW=%ESC%%YELLOW%" & set "CYAN=%ESC%%CYAN%" & set "NC=%ESC%%NC%"

REM ---- 初始化日志 ----
echo ============================================ > "%LOG_FILE%"
echo   build_php.bat 日志 - %DATE% %TIME%         >> "%LOG_FILE%"
echo ============================================ >> "%LOG_FILE%"

REM ---- 辅助函数 ----
goto :main

:info
echo %GREEN%[INFO]%NC%  %~1
echo [INFO]  %~1 >> "%LOG_FILE%"
goto :eof

:warn
echo %YELLOW%[WARN]%NC%  %~1
echo [WARN]  %~1 >> "%LOG_FILE%"
goto :eof

:step
echo %CYAN%[STEP]%NC%  %~1
echo [STEP]  %~1 >> "%LOG_FILE%"
goto :eof

:err
echo.
echo %RED%========================================%NC%
echo %RED%  错误: %~1%NC%
echo %RED%========================================%NC%
echo.
echo [ERROR] %~1 >> "%LOG_FILE%"
pause
exit /b 1
goto :eof

:check_ok
echo   %GREEN%[OK]%NC% %~1
echo   [OK] %~1 >> "%LOG_FILE%"
goto :eof

REM ---- 检查管理员权限 ----
:check_admin
net session >nul 2>&1
if %errorlevel% neq 0 (
    call :warn "未以管理员身份运行，部分功能可能失败（如安装服务、修改 hosts）"
    call :warn "建议右键 → 以管理员身份运行"
    timeout /t 3 /nobreak >nul
)
goto :eof

REM ---- 系统环境检查 ----
:pre_check
call :step "[0] 系统环境检查..."

REM 检查操作系统
ver | find "10." >nul && call :check_ok "操作系统: Windows 10/11" || (
    ver | find "11." >nul && call :check_ok "操作系统: Windows 11" || (
        call :warn "操作系统可能不兼容，建议 Windows 10/11 或 Windows Server 2016+"
    )
)

REM 检查 CPU 架构
if "%PROCESSOR_ARCHITECTURE%"=="AMD64" (
    call :check_ok "CPU 架构: x86_64 (64-bit)"
) else (
    call :err "需要 64 位操作系统，当前: %PROCESSOR_ARCHITECTURE%"
)

REM 检查内存
for /f "tokens=2 delims==" %%a in ('wmic os get TotalVisibleMemorySize /value ^| find "="') do set "MEM_KB=%%a"
if defined MEM_KB (
    set /a "MEM_GB=%MEM_KB% / 1024 / 1024"
    if !MEM_GB! geq 4 (
        call :check_ok "内存: !MEM_GB!GB (>= 4GB)"
    ) else (
        call :warn "内存: !MEM_GB!GB (建议 >= 4GB)"
    )
)

REM 检查磁盘空间
for /f "tokens=3" %%a in ('dir /-c %INSTALL_ROOT% 2^>nul ^| find "可用字节"') do set "FREE_BYTES=%%a"
if defined FREE_BYTES (
    set /a "FREE_GB=%FREE_BYTES% / 1024 / 1024 / 1024"
    if !FREE_GB! geq 10 (
        call :check_ok "磁盘空间: !FREE_GB!GB (>= 10GB)"
    ) else (
        call :warn "磁盘空间: !FREE_GB!GB (建议 >= 10GB)"
    )
)

REM 检查 VC++ Redistributable
reg query "HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" >nul 2>&1
if %errorlevel% equ 0 (
    call :check_ok "VC++ Redistributable: 已安装"
) else (
    call :warn "VC++ Redistributable 未检测到，将在后续步骤安装"
)

REM 检查 curl
where curl >nul 2>&1
if %errorlevel% equ 0 (
    for /f "tokens=1-2" %%a in ('curl --version 2^>^&1 ^| head -1') do call :check_ok "curl: %%a %%b"
) else (
    call :warn "curl 未找到，将使用 PowerShell 下载"
)

REM 检查 tar（Win10 1803+ 内置）
where tar >nul 2>&1 && call :check_ok "tar: 已可用" || call :warn "tar 未找到，部分解压可能失败"

REM 检查 PowerShell
where powershell >nul 2>&1 && call :check_ok "PowerShell: 已可用" || call :err "PowerShell 不可用"

echo.
goto :eof

REM ---- 下载文件（curl 优先 → PowerShell 回退）----
:download
REM 参数: %1=URL  %2=目标文件名
set "DL_URL=%~1"
set "DL_FILE=%~2"

if exist "%DL_FILE%" (
    REM 简单检查文件大小 > 1KB
    for %%F in ("%DL_FILE%") do if %%~zF gtr 1024 (
        call :info "  使用本地: %DL_FILE%"
        goto :eof
    ) else (
        call :warn "  文件损坏，重新下载: %DL_FILE%"
        del "%DL_FILE%" 2>nul
    )
)

REM 也检查 SCRIPT_DIR 下的同名文件
set "LOCAL_COPY=%SCRIPT_DIR%%DL_FILE%"
if exist "%LOCAL_COPY%" (
    for %%F in ("%LOCAL_COPY%") do if %%~zF gtr 1024 (
        call :info "  使用本地副本: %LOCAL_COPY%"
        copy /y "%LOCAL_COPY%" "%DL_FILE%" >nul 2>&1
        goto :eof
    )
)

call :info "  下载: %DL_URL%"

where curl >nul 2>&1
if %errorlevel% equ 0 (
    curl -L --progress-bar -o "%DL_FILE%" "%DL_URL%"
    if %errorlevel% neq 0 (
        call :err "下载失败: %DL_URL%"
    )
) else (
    powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%DL_URL%' -OutFile '%DL_FILE%'" 2>>"%LOG_FILE%"
    if %errorlevel% neq 0 (
        call :err "下载失败: %DL_URL%"
    )
)

call :check_ok "下载完成: %DL_FILE%"
goto :eof

REM ---- 解压 zip/tar.gz ----
:extract
REM 参数: %1=压缩包路径  %2=目标目录
set "ARC_FILE=%~1"
set "DEST_DIR=%~2"

echo %ARC_FILE% | find ".zip" >nul
if %errorlevel% equ 0 (
    call :info "  解压 ZIP: %ARC_FILE%"
    if exist "%DEST_DIR%" rmdir /s /q "%DEST_DIR%" 2>nul
    powershell -Command "Expand-Archive -Path '%ARC_FILE%' -DestinationPath '%DEST_DIR%' -Force" 2>>"%LOG_FILE%"
    goto :eof
)

echo %ARC_FILE% | find ".tar.gz" >nul
if %errorlevel% equ 0 (
    call :info "  解压 tar.gz: %ARC_FILE%"
    if exist "%DEST_DIR%" rmdir /s /q "%DEST_DIR%" 2>nul
    mkdir "%DEST_DIR%" 2>nul
    where tar >nul 2>&1
    if %errorlevel% equ 0 (
        tar -xzf "%ARC_FILE%" -C "%DEST_DIR%" 2>>"%LOG_FILE%"
    ) else (
        powershell -Command "tar -xzf '%ARC_FILE%' -C '%DEST_DIR%'" 2>>"%LOG_FILE%"
    )
    goto :eof
)

REM 其他格式
echo %ARC_FILE% | find ".tar" >nul
if %errorlevel% equ 0 (
    call :info "  解压 tar: %ARC_FILE%"
    if exist "%DEST_DIR%" rmdir /s /q "%DEST_DIR%" 2>nul
    mkdir "%DEST_DIR%" 2>nul
    tar -xf "%ARC_FILE%" -C "%DEST_DIR%" 2>>"%LOG_FILE%"
    goto :eof
)
goto :eof

REM ---- 添加 PATH 环境变量 ----
:add_to_path
REM 参数: %1=要添加的目录路径
set "NEW_PATH=%~1"
echo %PATH% | find /i "%NEW_PATH%" >nul
if %errorlevel% neq 0 (
    setx PATH "%PATH%;%NEW_PATH%" >nul 2>&1
    set "PATH=%PATH%;%NEW_PATH%"
    call :info "  已添加 PATH: %NEW_PATH%"
) else (
    call :info "  PATH 已存在: %NEW_PATH%"
)
goto :eof

REM ============================================================
REM 主流程
REM ============================================================
:main

echo.
echo ============================================
echo   Windows PHP 运行环境安装脚本
echo   PHP %PHP_VERSION% + Apache %HTTPD_VERSION%
echo   禅道开源版一键部署
echo ============================================
echo.

REM 记录开始时间
set "START_TIME=%TIME%"

REM ---- 检查管理员权限 ----
call :check_admin

REM ---- 0. 系统环境检查 ----
call :pre_check

REM ---- 1. 创建构建临时目录 ----
call :step "[1/10] 准备构建目录..."
if not exist "%TEMP_DIR%" mkdir "%TEMP_DIR%"
call :check_ok "临时目录: %TEMP_DIR%"

REM ---- 2. 安装 VC++ Redistributable ----
call :step "[2/10] VC++ Redistributable..."
reg query "HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" >nul 2>&1
if %errorlevel% equ 0 (
    call :info "  VC++ Redistributable 已安装，跳过"
) else (
    call :info "  正在下载 VC++ Redistributable..."
    pushd "%TEMP_DIR%"
    call :download "%VC_REDIST_URL%" "vc_redist.x64.exe"
    call :info "  正在安装（静默模式）..."
    start /wait vc_redist.x64.exe /install /quiet /norestart
    if %errorlevel% equ 0 (
        call :check_ok "VC++ Redistributable 安装完成"
    ) else (
        call :warn "VC++ Redistributable 安装可能失败，继续尝试..."
    )
    popd
)

REM ---- 3. 检测已安装的 PHP ----
call :step "[3/10] 检测 PHP..."
set "PHP_ALREADY_INSTALLED=0"
if exist "%PHP_DIR%\php.exe" (
    for /f "tokens=1-2" %%a in ('"%PHP_DIR%\php.exe" -v 2^>^&1 ^| find "PHP"') do (
        call :info "  PHP 已安装: %%a %%b"
    )
    set "PHP_ALREADY_INSTALLED=1"
) else (
    call :info "  PHP 未安装，将下载预编译版本"
)
REM 也检查 PATH 中的 php
where php >nul 2>&1
if %errorlevel% equ 0 (
    for /f "tokens=1-2" %%a in ('php -v 2^>^&1 ^| find "PHP"') do (
        call :info "  系统 PATH 中 PHP: %%a %%b"
    )
)

REM ---- 4. 检测已安装的 Apache ----
call :step "[4/10] 检测 Apache..."
set "APACHE_ALREADY_INSTALLED=0"
if exist "%HTTPD_DIR%\bin\httpd.exe" (
    for /f "tokens=1-2" %%a in ('"%HTTPD_DIR%\bin\httpd.exe" -v 2^>^&1 ^| find "Apache"') do (
        call :info "  Apache 已安装: %%a %%b"
    )
    set "APACHE_ALREADY_INSTALLED=1"
) else (
    call :info "  Apache 未安装，将下载预编译版本"
)

REM ---- 5. 下载并安装 PHP ----
call :step "[5/10] 安装 PHP %PHP_VERSION%..."
if "!PHP_ALREADY_INSTALLED!"=="1" (
    call :info "  PHP 已存在，跳过安装"
) else (
    pushd "%TEMP_DIR%"

    REM PHP 8.1.x 下载地址（Thread-Safe, x64, VS16）
    set "PHP_ZIP=php-%PHP_VERSION%-Win32-%VC_VERSION%-x64.zip"
    set "PHP_URL=https://windows.php.net/downloads/releases/!PHP_ZIP!"

    REM 如果版本含 -nts 则是 Non-Thread-Safe
    echo %PHP_VERSION% | find "nts" >nul
    if %errorlevel% equ 0 (
        set "PHP_ZIP=php-%PHP_VERSION%-Win32-%VC_VERSION%-x64.zip"
        set "PHP_URL=https://windows.php.net/downloads/releases/!PHP_ZIP!"
    )

    call :info "  PHP 下载地址: !PHP_URL!"
    call :download "!PHP_URL!" "!PHP_ZIP!"

    call :info "  解压 PHP 到 %PHP_DIR%..."
    if exist "%PHP_DIR%" rmdir /s /q "%PHP_DIR%" 2>nul
    mkdir "%PHP_DIR%" 2>nul
    powershell -Command "Expand-Archive -Path '%TEMP_DIR%\!PHP_ZIP!' -DestinationPath '%PHP_DIR%' -Force" 2>>"%LOG_FILE%"

    REM 添加到 PATH
    call :add_to_path "%PHP_DIR%"
    call :add_to_path "%PHP_DIR%\ext"

    popd
)

REM ---- 验证 PHP ----
if exist "%PHP_DIR%\php.exe" (
    for /f "tokens=1-2" %%a in ('"%PHP_DIR%\php.exe" -v 2^>^&1 ^| find "PHP"') do (
        call :check_ok "PHP: %%a %%b"
    )
) else (
    call :err "PHP 安装验证失败: %PHP_DIR%\php.exe 不存在"
)

REM ---- 6. 下载并安装 Apache ----
call :step "[6/10] 安装 Apache %HTTPD_VERSION%..."
if "!APACHE_ALREADY_INSTALLED!"=="1" (
    call :info "  Apache 已存在，跳过安装"
) else (
    pushd "%TEMP_DIR%"

    REM Apache Lounge 预编译版本
    REM 文件名格式: httpd-%HTTPD_VERSION%-win64-VS16.zip
    for /f "tokens=1-2 delims=." %%a in ("%HTTPD_VERSION%") do set "APACHE_VER=%%a%%b"
    set "APACHE_ZIP=httpd-%HTTPD_VERSION%-win64-VS16.zip"
    set "APACHE_URL=https://www.apachelounge.com/download/VS16/binaries/!APACHE_ZIP!"

    call :info "  Apache 下载地址: !APACHE_URL!"
    call :download "!APACHE_URL!" "!APACHE_ZIP!"

    call :info "  解压 Apache 到 %HTTPD_DIR%..."
    if exist "%HTTPD_DIR%" rmdir /s /q "%HTTPD_DIR%" 2>nul
    mkdir "%HTTPD_DIR%" 2>nul
    powershell -Command "Expand-Archive -Path '%TEMP_DIR%\!APACHE_ZIP!' -DestinationPath '%TEMP_DIR%\apache_extract' -Force" 2>>"%LOG_FILE%"

    REM Apache Lounge 的 zip 内部有一个 Apache24 目录
    if exist "%TEMP_DIR%\apache_extract\Apache24" (
        xcopy /e /y "%TEMP_DIR%\apache_extract\Apache24\*" "%HTTPD_DIR%\" >nul 2>&1
        rmdir /s /q "%TEMP_DIR%\apache_extract" 2>nul
    ) else (
        xcopy /e /y "%TEMP_DIR%\apache_extract\*" "%HTTPD_DIR%\" >nul 2>&1
        rmdir /s /q "%TEMP_DIR%\apache_extract" 2>nul
    )

    REM 添加到 PATH
    call :add_to_path "%HTTPD_DIR%\bin"

    popd
)

REM ---- 验证 Apache ----
if exist "%HTTPD_DIR%\bin\httpd.exe" (
    for /f "tokens=1-2" %%a in ('"%HTTPD_DIR%\bin\httpd.exe" -v 2^>^&1 ^| find "Apache"') do (
        call :check_ok "Apache: %%a %%b"
    )
) else (
    call :err "Apache 安装验证失败: %HTTPD_DIR%\bin\httpd.exe 不存在"
)

REM ---- 7. 配置 php.ini ----
call :step "[7/10] 配置 PHP..."
pushd "%PHP_DIR%"

REM 从 php.ini-production 或 php.ini-development 复制
if not exist "php.ini" (
    if exist "php.ini-production" (
        copy /y "php.ini-production" "php.ini" >nul
        call :info "  基于 php.ini-production 创建 php.ini"
    ) else if exist "php.ini-development" (
        copy /y "php.ini-development" "php.ini" >nul
        call :info "  基于 php.ini-development 创建 php.ini"
    ) else (
        call :warn "  未找到 php.ini-production，将创建默认 php.ini"
    )
)

REM 写一个简单的补充配置
set "ZENTAO_INI=%PHP_DIR%\zentao.ini"
(
echo ; ============================================================
echo ; 禅道 PHP 配置 - 由 build_php.bat 自动生成
echo ; ============================================================
echo [PHP]
echo memory_limit = 512M
echo post_max_size = 100M
echo upload_max_filesize = 100M
echo max_execution_time = 300
echo max_input_time = 300
echo date.timezone = Asia/Shanghai
echo.
echo ; 扩展启用
echo extension_dir = "ext"
echo extension=curl
echo extension=fileinfo
echo extension=gd
echo extension=intl
echo extension=mbstring
echo extension=exif
echo extension=mysqli
echo extension=openssl
echo extension=pdo_mysql
echo extension=zip
echo extension=dom
echo extension=xml
echo.
echo ; OPcache
echo zend_extension=php_opcache.dll
echo opcache.enable=1
echo opcache.memory_consumption=256
echo opcache.interned_strings_buffer=16
echo opcache.max_accelerated_files=10000
echo opcache.validate_timestamps=1
echo.
echo ; Session
echo session.save_path = "%TEMP%"
echo.
echo ; 错误报告（生产环境用）
echo display_errors = Off
echo log_errors = On
echo error_log = "%HTTPD_DIR%\logs\php_error.log"
) > "%ZENTAO_INI%"

call :info "  已创建: %ZENTAO_INI%"

REM 确保 ext 目录正确
if exist "ext\php_curl.dll" (
    call :check_ok "PHP 扩展目录: ext\"
) else (
    call :warn "PHP 扩展目录可能不对，请检查 ext\ 路径"
)

popd

REM ---- 8. 配置 Apache ----
call :step "[8/10] 配置 Apache..."

REM 备份原 httpd.conf
if exist "%HTTPD_DIR%\conf\httpd.conf" (
    if not exist "%HTTPD_DIR%\conf\httpd.conf.bak" (
        copy /y "%HTTPD_DIR%\conf\httpd.conf" "%HTTPD_DIR%\conf\httpd.conf.bak" >nul
        call :info "  已备份原 httpd.conf"
    )
)

REM 生成新的 httpd.conf
set "HTTPD_CONF=%HTTPD_DIR%\conf\httpd.conf"
(
echo # ============================================================
echo # Apache 配置 - 由 build_php.bat 自动生成
echo # ============================================================
echo Define SRVROOT "%HTTPD_DIR%"
echo ServerRoot "%HTTPD_DIR%"
echo.
echo # 监听端口
echo Listen 8080
echo.
echo # 加载模块
echo LoadModule access_compat_module modules/mod_access_compat.so
echo LoadModule actions_module modules/mod_actions.so
echo LoadModule alias_module modules/mod_alias.so
echo LoadModule allowmethods_module modules/mod_allowmethods.so
echo LoadModule asis_module modules/mod_asis.so
echo LoadModule auth_basic_module modules/mod_auth_basic.so
echo LoadModule authn_core_module modules/mod_authn_core.so
echo LoadModule authn_file_module modules/mod_authn_file.so
echo LoadModule authz_core_module modules/mod_authz_core.so
echo LoadModule authz_groupfile_module modules/mod_authz_groupfile.so
echo LoadModule authz_host_module modules/mod_authz_host.so
echo LoadModule authz_user_module modules/mod_authz_user.so
echo LoadModule autoindex_module modules/mod_autoindex.so
echo LoadModule deflate_module modules/mod_deflate.so
echo LoadModule dir_module modules/mod_dir.so
echo LoadModule env_module modules/mod_env.so
echo LoadModule headers_module modules/mod_headers.so
echo LoadModule log_config_module modules/mod_log_config.so
echo LoadModule mime_module modules/mod_mime.so
echo LoadModule negotiation_module modules/mod_negotiation.so
echo LoadModule rewrite_module modules/mod_rewrite.so
echo LoadModule setenvif_module modules/mod_setenvif.so
echo LoadModule socache_shmcb_module modules/mod_socache_shmcb.so
echo LoadModule ssl_module modules/mod_ssl.so
echo LoadModule status_module modules/mod_status.so
echo LoadModule proxy_module modules/mod_proxy.so
echo LoadModule proxy_fcgi_module modules/mod_proxy_fcgi.so
echo.
echo # PHP 模块
echo LoadModule php_module "%PHP_DIR:\=/%/php8apache2_4.dll"
echo.
echo # 基础配置
echo ServerAdmin admin@localhost
echo ServerName localhost:8080
echo.
echo ^<Directory /^>
echo     AllowOverride none
echo     Require all denied
echo ^</Directory^>
echo.
echo DocumentRoot "%ZENTAO_DIR:\=/%/www"
echo.
echo ^<Directory "%ZENTAO_DIR:\=/%/www"^>
echo     Options Indexes FollowSymLinks
echo     AllowOverride All
echo     Require all granted
echo ^</Directory^>
echo.
echo ^<IfModule dir_module^>
echo     DirectoryIndex index.php index.html
echo ^</IfModule^>
echo.
echo ^<FilesMatch "\.php$"^>
echo     SetHandler application/x-httpd-php
echo ^</FilesMatch^>
echo.
echo # PHP 配置文件路径
echo PHPIniDir "%PHP_DIR:\=/%"
echo.
echo # 日志
echo ErrorLog "logs/error.log"
echo LogLevel warn
echo.
echo ^<IfModule log_config_module^>
echo     LogFormat "%%h %%l %%u %%t \"%%r\" %%^>s %%b \"%%{Referer}i\" \"%%{User-Agent}i\"" combined
echo     CustomLog "logs/access.log" combined
echo ^</IfModule^>
echo.
echo ^<IfModule mime_module^>
echo     TypesConfig conf/mime.types
echo     AddType application/x-compress .Z
echo     AddType application/x-gzip .gz .tgz
echo ^</IfModule^>
echo.
echo # SSL 配置（如需 HTTPS 请修改）
echo ^<IfModule ssl_module^>
echo     SSLRandomSeed startup builtin
echo     SSLRandomSeed connect builtin
echo ^</IfModule^>
echo.
echo EnableMMAP off
echo EnableSendfile on
) > "%HTTPD_CONF%"

call :check_ok "Apache 配置已生成: %HTTPD_CONF%"

REM 创建 logs 目录
if not exist "%HTTPD_DIR%\logs" mkdir "%HTTPD_DIR%\logs" 2>nul

REM ---- 9. 部署禅道源码 ----
call :step "[9/10] 部署禅道源码..."

REM 检查本地 zentaopms.zip
set "ZENTAO_ZIP=%SCRIPT_DIR%zentaopms.zip"
if exist "!ZENTAO_ZIP!" (
    call :info "  解压本地: !ZENTAO_ZIP!"
    if exist "%ZENTAO_DIR%" rmdir /s /q "%ZENTAO_DIR%" 2>nul
    powershell -Command "Expand-Archive -Path '!ZENTAO_ZIP!' -DestinationPath '%TEMP_DIR%\zentaopms_extract' -Force" 2>>"%LOG_FILE%"
    REM 处理解压后的目录结构（可能包含版本号的子目录）
    for /d %%d in ("%TEMP_DIR%\zentaopms_extract\zentaopms-*") do (
        xcopy /e /y "%%d\*" "%ZENTAO_DIR%\" >nul 2>&1
        goto :zentao_extracted
    )
    REM 没有版本号子目录，直接复制
    xcopy /e /y "%TEMP_DIR%\zentaopms_extract\*" "%ZENTAO_DIR%\" >nul 2>&1
    rmdir /s /q "%TEMP_DIR%\zentaopms_extract" 2>nul
    goto :zentao_extracted
)

REM 没有 zip 的话检查本地是否已有源码
if exist "%SCRIPT_DIR%..\source\www\index.php" (
    call :info "  使用本地源码: %SCRIPT_DIR%..\source\"
    if exist "%ZENTAO_DIR%" rmdir /s /q "%ZENTAO_DIR%" 2>nul
    xcopy /e /y "%SCRIPT_DIR%..\source\*" "%ZENTAO_DIR%\" >nul 2>&1
    goto :zentao_extracted
)

REM zip 也不存在，创建一个基本测试页面
call :warn "  未找到 zentaopms.zip，将创建测试页面"
if not exist "%ZENTAO_DIR%\www" mkdir "%ZENTAO_DIR%\www" 2>nul
(
echo ^<?php
echo phpinfo^(^);
echo ?^>
) > "%ZENTAO_DIR%\www\index.php"
call :info "  已创建测试页面: %ZENTAO_DIR%\www\index.php"

:zentao_extracted
REM 创建必要的目录
if not exist "%ZENTAO_DIR%\www\data" mkdir "%ZENTAO_DIR%\www\data" 2>nul
if not exist "%ZENTAO_DIR%\tmp" mkdir "%ZENTAO_DIR%\tmp" 2>nul
if not exist "%ZENTAO_DIR%\log" mkdir "%ZENTAO_DIR%\log" 2>nul

call :check_ok "禅道目录: %ZENTAO_DIR%"

REM ---- 10. 生成数据库配置文件 ----
call :step "[10/10] 创建数据库配置..."

set "MY_PHP=%ZENTAO_DIR%\config\my.php"
if not exist "%ZENTAO_DIR%\config" mkdir "%ZENTAO_DIR%\config" 2>nul

(
echo ^<?php
echo /** 禅道数据库配置 - 由 build_php.bat 自动生成 */
echo $config->installed       = true;
echo $config->debug           = false;
echo $config->requestType     = 'PATH_INFO';
echo $config->timezone        = 'Asia/Shanghai';
echo $config->db->host        = '192.168.0.102';
echo $config->db->port        = '3306';
echo $config->db->name        = 'zendao';
echo $config->db->user        = 'root';
echo $config->db->password    = 'Kd9$prL7sQ2!vzB4';
echo $config->db->prefix      = 'zt_';
echo $config->db->driver      = 'pdo';
echo $config->default->lang   = 'zh-cn';
) > "%MY_PHP%"

call :check_ok "数据库配置: %MY_PHP%"

REM ---- 配置文件权限（Windows 上确保可读写）----
icacls "%ZENTAO_DIR%\www\data" /grant Everyone:F /t >nul 2>&1
icacls "%ZENTAO_DIR%\tmp" /grant Everyone:F /t >nul 2>&1
icacls "%ZENTAO_DIR%\log" /grant Everyone:F /t >nul 2>&1

REM ---- 11. 验证安装 ----
call :step "[验证] 最终检查..."

set "FAILED=0"

if exist "%PHP_DIR%\php.exe" (
    echo   %GREEN%[OK]%NC% PHP:   %PHP_DIR%\php.exe
) else (
    echo   %RED%[FAIL]%NC% PHP 未找到
    set "FAILED=1"
)

if exist "%HTTPD_DIR%\bin\httpd.exe" (
    echo   %GREEN%[OK]%NC% Apache: %HTTPD_DIR%\bin\httpd.exe
) else (
    echo   %RED%[FAIL]%NC% Apache 未找到
    set "FAILED=1"
)

if exist "%ZENTAO_DIR%\www\index.php" (
    echo   %GREEN%[OK]%NC% 禅道:   %ZENTAO_DIR%\www\index.php
) else (
    echo   %RED%[FAIL]%NC% 禅道源码未找到
    set "FAILED=1"
)

if exist "%MY_PHP%" (
    echo   %GREEN%[OK]%NC% 配置:   %MY_PHP%
) else (
    echo   %RED%[FAIL]%NC% 数据库配置未找到
    set "FAILED=1"
)

REM 测试 Apache 配置语法
"%HTTPD_DIR%\bin\httpd.exe" -t >nul 2>&1
if %errorlevel% equ 0 (
    echo   %GREEN%[OK]%NC% Apache 配置语法
) else (
    echo   %RED%[FAIL]%NC% Apache 配置语法有误
    "%HTTPD_DIR%\bin\httpd.exe" -t 2>&1 | find "error"
    set "FAILED=1"
)

if "%FAILED%"=="1" (
    call :err "部分检查未通过，请检查日志: %LOG_FILE%"
)

REM ---- 12. 安装 Apache 为 Windows 服务 ----
call :step "[服务] 安装 Apache 服务..."

REM 先停止可能存在的旧服务
sc query Apache2.4 >nul 2>&1
if %errorlevel% equ 0 (
    net stop Apache2.4 >nul 2>&1
    sc delete Apache2.4 >nul 2>&1
    call :info "  已移除旧 Apache2.4 服务"
)

"%HTTPD_DIR%\bin\httpd.exe" -k install -n "Apache2.4" >nul 2>&1
if %errorlevel% equ 0 (
    call :check_ok "Apache 服务安装成功（Apache2.4）"
) else (
    REM 可能已有同名服务，尝试直接启动
    call :warn "  Apache 服务安装跳过（可能已存在），尝试启动..."
)

REM ---- 13. 启动 Apache ----
call :step "[启动] 启动 Apache..."

net stop Apache2.4 >nul 2>&1
timeout /t 2 /nobreak >nul
net start Apache2.4 >nul 2>&1
if %errorlevel% equ 0 (
    call :check_ok "Apache 服务已启动"
) else (
    call :warn "Apache 服务启动失败，尝试前台运行..."
    REM 前台启动用于调试
    start "Apache HTTP Server" "%HTTPD_DIR%\bin\httpd.exe" -D FOREGROUND
    call :info "  Apache 已前台启动，关闭此窗口将停止服务"
)

REM ---- 14. 验证 HTTP ----
call :info "等待 Apache 启动..."
timeout /t 3 /nobreak >nul

set "HTTP_OK=0"
for /l %%i in (1,1,5) do (
    curl -s -o nul -w "%%{http_code}" http://127.0.0.1:8080/ 2>nul | findstr /r "^200 ^302 ^301" >nul
    if !errorlevel! equ 0 (
        set "HTTP_OK=1"
        call :check_ok "HTTP 响应正常 (%%i/5)"
        goto :http_done
    )
    echo   等待... (%%i/5)
    timeout /t 2 /nobreak >nul
)
call :warn "HTTP 未在预期时间内响应，请检查 %HTTPD_DIR%\logs\error.log"

:http_done

REM ---- 15. 完成 ----
set "END_TIME=%TIME%"
echo.
echo ============================================
echo   安装完成！
echo ============================================
echo.
echo   PHP:        %PHP_DIR%
echo   Apache:     %HTTPD_DIR%
echo   禅道:       %ZENTAO_DIR%
echo   数据库:     192.168.0.102:3306/zendao
echo   访问地址:   http://127.0.0.1:8080
echo   日志:       %HTTPD_DIR%\logs\error.log
echo   配置文件:   %MY_PHP%
echo.
echo   常用命令:
echo     net stop Apache2.4         停止 Apache
echo     net start Apache2.4        启动 Apache
echo     httpd -t                   检查配置
echo     httpd -k restart           重启 Apache
echo.
echo   下一步:
echo     1. 确保 MySQL 可达: 192.168.0.102:3306
echo     2. 浏览器访问: http://127.0.0.1:8080
echo     3. 如需修改数据库: 编辑 %MY_PHP%
echo.
echo   日志文件: %LOG_FILE%
echo ============================================

call :info "脚本结束 (开始: %START_TIME%, 结束: %END_TIME%)"

REM 清理临时文件
rmdir /s /q "%TEMP_DIR%" 2>nul

endlocal
pause
exit /b 0
