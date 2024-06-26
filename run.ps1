#!/usr/bin/env pwsh
Set-StrictMode -v latest
$ErrorActionPreference = "Stop"

function Main() {
    [string] $password = Generate-AlphanumericPassword 20
    Update-Configfiles $password

    docker ps | grep -v "^CONTAINER" | awk '{print $1}' | xargs -r docker stop

    docker ps

    [string] $curdir = (Get-Location).Path
    [string] $bindmount = "$($curdir)/tests:/tests"

    [string] $containerImageMysql = "mysql"
    [string] $containerImagePostgres = "postgres"
    [string] $containerImageSqlserver = "mcr.microsoft.com/mssql/server"
    [string] $containerImageElasticsearch = "elasticsearch:8.14.1"

    [string] $containerMysql = $(docker ps | grep $containerImageMysql | awk '{print $1}')
    if ($containerMysql) {
        Log "Reusing existing mysql container: $containerMysql"
    }
    else {
        Log "Starting $($containerImageMysql):"
        docker run -d -p 3306:3306 -v $bindmount -e "MYSQL_ROOT_PASSWORD=$password" $containerImageMysql
        [string] $containerMysql = $(docker ps | grep $containerImageMysql | awk '{print $1}')
    }

    [string] $containerPostgres = $(docker ps | grep $containerImagePostgres | awk '{print $1}')
    if ($containerPostgres) {
        Log "Reusing existing postgres container: $containerPostgres"
    }
    else {
        Log "Starting $($containerImagePostgres):"
        docker run -d -p 5432:5432 -v $bindmount -e "POSTGRES_PASSWORD=$password" $containerImagePostgres
        [string] $containerPostgres = $(docker ps | grep $containerImagePostgres | awk '{print $1}')
    }

    [string] $containerSqlserver = $(docker ps | grep $containerImageSqlserver | awk '{print $1}')
    if ($containerSqlserver) {
        Log "Reusing existing sqlserver container: $containerSqlserver"
    }
    else {
        Log "Starting $($containerImageSqlserver):"
        docker run -d -p 1433:1433 -v $bindmount -e 'ACCEPT_EULA=Y' -e "SA_PASSWORD=$password" $containerImageSqlserver
        [string] $containerSqlserver = $(docker ps | grep $containerImageSqlserver | awk '{print $1}')
    }

    [string] $containerElasticsearch = $(docker ps | grep $containerImageElasticsearch | awk '{print $1}')
    if ($containerElasticsearch) {
        Log "Reusing existing elasticsearch container: $containerElasticsearch"
    }
    else {
        Log "Starting $($containerImageElasticsearch):"
        docker run -d -p 9200:9200 -v $bindmount -e 'discovery.type=single-node' -e "ELASTIC_PASSWORD=$password" $containerImageElasticsearch
        [string] $containerElasticsearch = $(docker ps | grep $containerImageElasticsearch | awk '{print $1}')
    }

    Download-SqlCmd
    Compile-Isatty

    Log "Waiting for containers to start up..."
    Start-Sleep 30

    Log "Running containers:"
    docker ps

    Log "Running mysql script in $($containerMysql):"
    docker exec $containerMysql /tests/setupmysql.sh

    Log "Running postgres script in $($containerPostgres):"
    docker exec $containerPostgres /tests/setuppostgres.sh

    Log "Running sqlserver script in $($containerSqlserver):"
    docker exec $containerSqlserver /tests/setupsqlserver.sh

    Log "Waiting for elasticsearch startup..."
    [int] $seconds = 0
    do {
        docker cp "$($containerElasticsearch):/usr/share/elasticsearch/config/certs/http_ca.crt" .
        Log ($seconds++)
        if ($seconds -eq 300 ) {
            Log "Couldn't retrieve elasticsearch ca cert."
            exit 1
        }
        Start-Sleep 1
    }
    while (!([IO.File]::Exists("http_ca.crt")) -or (dir http_ca.crt).Length -eq 0)
    Log ("Got elasticsearch cert: $((dir http_ca.crt).Length) bytes file.")

    [bool] $testfail = $false

    Log "Importing mysql:"
    dotnet run --project src configMysql.json
    jq 'del(.took)' result.json > result_mysql.json
    diff result_mysql.json tests/expected_mysql.json
    if (!$?) {
        Log "Error: mysql."
        $testfail = $true
    }

    Log "Importing postgres:"
    dotnet run --project src configPostgres.json
    jq 'del(.took)' result.json > result_postgres.json
    diff result_postgres.json tests/expected_postgres.json
    if (!$?) {
        Log "Error: postgres."
        $testfail = $true
    }

    Log "Importing sqlserver:"
    dotnet run --project src configSqlserver.json
    jq 'del(.took)' result.json > result_sqlserver.json
    diff result_sqlserver.json tests/expected_sqlserver.json
    if (!$?) {
        Log "Error: sqlserver."
        $testfail = $true
    }

    Update-Configfiles ""

    if ($testfail) {
        exit 1
    }
}

function Download-SqlCmd() {
    [string] $arch = $(uname -m)
    if ($arch -ne "arm64" -and $arch -ne "aarch64") {
        return
    }
    $releasesurl = 'https://api.github.com/repos/microsoft/go-sqlcmd/releases/latest'
    $jqpattern = '.assets[] | select(.name|test("^sqlcmd-v[0-9\\.]+-linux-' + $arch + '\\.tar\\.bz2$")) | .browser_download_url'
    $asseturl = $(curl -s "$releasesurl" | jq "$jqpattern" -r)
    $filename = $(basename "$asseturl")
    Log "Downloading: '$asseturl' -> '$filename'"
    curl -Ls "$asseturl" -o "$filename"
    tar xf "$filename"
    rm "$filename"
    rm NOTICE.md
    rm sqlcmd_debug
    mv sqlcmd tests
}

function Compile-Isatty() {
    Log "Compiling isatty work around for mysql"
    echo "int isatty(int fd) { return 1; }" | gcc -O2 -fpic -shared -ldl -o tests/isatty.so -xc -
}

function Generate-AlphanumericPassword([int] $numberOfChars) {
    [char[]] $validChars = 'a'..'z' + 'A'..'Z' + [char]'0'..[char]'9'
    [string] $password = ""
    do {
        [string] $password = (1..$numberOfChars | ForEach-Object { $validChars[(Get-Random -Maximum $validChars.Length)] }) -join ""
    }
    while (
        !($password | ? { ($_.ToCharArray() | ? { [Char]::IsUpper($_) }) }) -or
        !($password | ? { ($_.ToCharArray() | ? { [Char]::IsLower($_) }) }) -or
        !($password | ? { ($_.ToCharArray() | ? { [Char]::IsDigit($_) }) }));

    return $password
}

function Update-Configfiles([string] $password) {
    $files = @(dir config*)
    foreach ($file in $files) {
        [string[]] $rows = Get-Content $file
        for ([int] $i = 0; $i -lt $rows.Length; $i++) {
            [int] $index1 = $rows[$i].IndexOf('Password=')
            if ($index1 -ge 0) {
                [int] $index2 = $rows[$i].IndexOf('"', $index1 + 9)
                if ($index2 -ge 0) {
                    $aa = $rows[$i]
                    $rows[$i] = $rows[$i].Substring(0, $index1 + 9) + $password + $rows[$i].Substring($index2)
                }
            }

            [int] $index1 = $rows[$i].IndexOf('"password": "')
            if ($index1 -ge 0) {
                [int] $index2 = $rows[$i].IndexOf('"', $index1 + 13)
                if ($index2 -ge 0) {
                    $aa = $rows[$i]
                    $rows[$i] = $rows[$i].Substring(0, $index1 + 13) + $password + $rows[$i].Substring($index2)
                }
            }
        }
        Set-Content $file $rows
    }
}

function Log($message) {
    Write-Host $message -f Cyan
}

Main
