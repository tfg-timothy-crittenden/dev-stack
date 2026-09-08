[CmdletBinding()]
param(
    [string]$ConnectUrl = 'http://localhost:18084',
    [int]$TimeoutSeconds = 60,
    [int]$RetryIntervalSeconds = 2,
    [string[]]$ConnectorFiles = @(
        (Join-Path $PSScriptRoot '..\debezium\classroom-outbox-connector.json'),
        (Join-Path $PSScriptRoot '..\debezium\material-outbox-connector.json')
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ConnectBaseUrl = $ConnectUrl.TrimEnd('/')

function Get-HttpStatusCode {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $response = $ErrorRecord.Exception.Response
    if ($null -ne $response -and $null -ne $response.StatusCode) {
        return [int]$response.StatusCode
    }

    return $null
}

function Invoke-ConnectRequest {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST', 'PUT')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [object]$Body
    )

    $uri = "$script:ConnectBaseUrl$Path"
    $invokeParams = @{
        Method      = $Method
        Uri         = $uri
        ContentType = 'application/json'
        ErrorAction = 'Stop'
    }

    if ($null -ne $Body) {
        $invokeParams.Body = ($Body | ConvertTo-Json -Depth 20)
    }

    return Invoke-RestMethod @invokeParams
}

function Wait-ForConnect {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null

    while ((Get-Date) -lt $deadline) {
        try {
            $plugins = Invoke-ConnectRequest -Method GET -Path '/connector-plugins'
            if ($null -ne $plugins) {
                $postgresPlugin = $plugins | Where-Object { $_.class -eq 'io.debezium.connector.postgresql.PostgresConnector' }
                if ($null -ne $postgresPlugin) {
                    return
                }
            }
        }
        catch {
            $lastError = $_
        }

        Start-Sleep -Seconds $RetryIntervalSeconds
    }

    if ($null -ne $lastError) {
        throw "Timed out waiting for Kafka Connect at $script:ConnectBaseUrl to become ready. Last error: $($lastError.Exception.Message)"
    }

    throw "Timed out waiting for Kafka Connect at $script:ConnectBaseUrl to become ready."
}

function Test-ConnectorExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        Invoke-ConnectRequest -Method GET -Path "/connectors/$([uri]::EscapeDataString($Name))" | Out-Null
        return $true
    }
    catch {
        $statusCode = Get-HttpStatusCode -ErrorRecord $_
        if ($statusCode -eq 404) {
            return $false
        }

        throw
    }
}

function Wait-ForConnectorRunning {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastStatus = $null

    while ((Get-Date) -lt $deadline) {
        try {
            $lastStatus = Invoke-ConnectRequest -Method GET -Path "/connectors/$([uri]::EscapeDataString($Name))/status"
            $connectorState = $lastStatus.connector.state
            $taskStates = @($lastStatus.tasks | ForEach-Object { $_.state })

            if ($connectorState -eq 'RUNNING' -and ($taskStates.Count -eq 0 -or ($taskStates | Where-Object { $_ -ne 'RUNNING' }).Count -eq 0)) {
                return $lastStatus
            }

            if ($connectorState -eq 'FAILED') {
                break
            }
        }
        catch {
            $lastStatus = $_
        }

        Start-Sleep -Seconds $RetryIntervalSeconds
    }

    if ($null -ne $lastStatus -and $lastStatus.PSObject.Properties.Name -contains 'connector') {
        $taskSummary = ($lastStatus.tasks | ForEach-Object { "$($_.id):$($_.state)" }) -join ', '
        throw "Connector '$Name' did not reach RUNNING state. Current connector state: $($lastStatus.connector.state). Task states: $taskSummary"
    }

    throw "Connector '$Name' did not reach RUNNING state within $TimeoutSeconds seconds."
}

function Register-Connector {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $resolvedPath = (Resolve-Path -Path $FilePath -ErrorAction Stop).Path
    $connector = Get-Content -Raw -Path $resolvedPath | ConvertFrom-Json

    if ([string]::IsNullOrWhiteSpace($connector.name)) {
        throw "Connector file '$resolvedPath' does not contain a valid 'name' property."
    }

    if ($null -eq $connector.config) {
        throw "Connector file '$resolvedPath' does not contain a valid 'config' object."
    }

    Write-Host "Processing connector '$($connector.name)' from '$resolvedPath'..."

    if (Test-ConnectorExists -Name $connector.name) {
        Write-Host "Updating existing connector '$($connector.name)'..."
        Invoke-ConnectRequest -Method PUT -Path "/connectors/$([uri]::EscapeDataString($connector.name))/config" -Body $connector.config | Out-Null
    }
    else {
        Write-Host "Creating connector '$($connector.name)'..."
        Invoke-ConnectRequest -Method POST -Path '/connectors' -Body $connector | Out-Null
    }

    $status = Wait-ForConnectorRunning -Name $connector.name
    Write-Host "Connector '$($connector.name)' is RUNNING."
    return $status
}

Write-Host "Waiting for Kafka Connect at $script:ConnectBaseUrl..."
Wait-ForConnect

foreach ($connectorFile in $ConnectorFiles) {
    Register-Connector -FilePath $connectorFile | Out-Null
}

Write-Host 'All Debezium connectors have been registered successfully.'

