#Requires -version 3.0

###############################################################################
# This is a quick and dirty way to download copies of twitter photos with a
# particular hashtag. It uses application-only 
###############################################################################

param(
    [Parameter(Mandatory=$True,Position=1, HelpMessage="Hashtag to download images for.")]
    [string]$HashTag,
    [Parameter(Mandatory=$True,Position=2, HelpMessage="Folder path for saving downloaded images.")]
    [string]$OutPath,
    [Parameter(Mandatory=$True,Position=3, HelpMessage="Twitter API Key.")]
    [string]$ApiKey,
    [Parameter(Mandatory=$True,Position=4, HelpMessage="Twitter API Secret.")]
    [string]$ApiSecret,
    [Parameter(Position=5, HelpMessage="Path to ExifTool.exe")]
    [string]$ExifToolPath
)

Add-Type -AssemblyName 'System.Web'

# make sure the output path exists
if ((Test-Path $outpath) -ne $true) { throw "Output path not found." }

# initialize objects to use for external processes
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.CreateNoWindow = $true
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $psi

# warn if no exiftool
# Download here: http://www.sno.phy.queensu.ca/~phil/exiftool/
if ([String]::IsNullOrWhiteSpace($ExifToolPath)) {
    Write-Warning "ExifTool not specified. No metadata will be written."
}
elseif ((Test-Path $ExifToolPath) -ne $true) {
    Write-Warning "ExifTool not found. No metadata will be written."
}
else { 
    $ExifToolFound = $true
    $psi.FileName = $ExifToolPath
}

function Get-TwitterBearerToken {
    <#
    .SYNOPSIS
        This function is used to request a bearer token from Twitter for Application-only authentication.
    .EXAMPLE
        Get-TwitterBearerToken -ConsumerKey 'XXXXXXXXXX' -ConsumerSecret 'XXXXXXXXXX'

        This example gets the bearer token string that can be used in subsequent requests against the Twitter API
    .PARAMETER ConsumerKey
        The Consumer Key string for your application, also known as the API Key.
    .PARAMETER ConsumerSecret
        The Consumer Secret string for your application, also known as the API Secret.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$ConsumerKey,
        [Parameter(Mandatory)]
        [string]$ConsumerSecret
    )
    
    begin {
		$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
		Set-StrictMode -Version Latest
        Add-Type -AssemblyName 'System.Web'
    }

    process {

        # This process is based on the following Twitter API documentation
        # https://dev.twitter.com/oauth/application-only

        # URL Encode the key and secret
        $ConsumerKey = [System.Web.HttpUtility]::UrlEncode($ConsumerKey)
        $ConsumerSecret = [System.Web.HttpUtility]::UrlEncode($ConsumerSecret)

        # Concat the values with a colon and base64 encode the whole thing
        $EncodedCredentials = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$($ConsumerKey):$($ConsumerSecret)"))

        # Send the bearer token request to the oauth2/token endpoint
        $response = Invoke-RestMethod -Uri 'https://api.twitter.com/oauth2/token' `
            -Method Post `
            -Headers @{Authorization="Basic $EncodedCredentials"} `
            -ContentType 'application/x-www-form-urlencoded;charset=UTF-8' `
            -Body 'grant_type=client_credentials'

        $response.access_token
    }
}

# get the bearer token
$token = Get-TwitterBearerToken -ConsumerKey $ApiKey -ConsumerSecret $ApiSecret

# check the output directory for the most recent ID we've already processed
$sinceID = gci $OutPath | %{
    if ($_.Name -match '^t(\d+)-.*\..{3}') { $matches[1] }
} | sort -Descending | select -first 1

# create the initial search query
$filter = [System.Web.HttpUtility]::UrlEncode("$HashTag filter:images -filter:retweets")
$initialQuery = "q=$filter&count=100&include_entities=1&result_type=recent"
if ($sinceID -ne $null) {
    $initialQuery = "$($initialQuery)&since_id=$sinceID"
}
$page = 0

# loop through results until there are no more or we reach our max
do {

    if ($response -eq $null) { $query = $initialQuery }
    else {
        # use the lowest ID we encountered minus 1 for the new max_id
        $lowestID--
        $query = "$($initialQuery)&max_id=$($lowestID)"
    }

    $response = Invoke-RestMethod -Uri "https://api.twitter.com/1.1/search/tweets.json?$query" `
        -Method Get `
        -Headers @{Authorization="Bearer $token"} `
        -ContentType 'application/x-www-form-urlencoded;charset=UTF-8'

    # debug info
    $page++
    write-host "--- PAGE $page --- $([System.Web.HttpUtility]::UrlDecode($query))"

    foreach ($status in $response.statuses) {

        # keep track of the lowest ID we find
        $lowestID = $status.id

        $i = -1
        foreach ($url in $status.entities.media.media_url) {

            # tweets can technically have multiple images attached,
            # so keep an index for file naming conflicts
            $i++

            # grab the extension from the original file
            $ext = $url.Substring($url.LastIndexOf('.'))

            # generate the downloaded file name/path
            $outfile = "t$($status.id)-$($status.user.screen_name)$(if ($i -gt 0) { "-$i" })$($ext)"
            $outfullpath = join-path $OutPath $outfile

            write-output "Downloading $outfile"
            Invoke-WebRequest $url -OutFile $outfullpath

            # write metadata if we have exiftool available
            if ($ExifToolFound -eq $true) {

                $created = [DateTime]::ParseExact($status.created_at, "ddd MMM dd HH:mm:ss zzzz yyyy", [System.Globalization.CultureInfo]::InvariantCulture)
                $psi.Arguments = @("-Artist=`"@$($status.user.screen_name)`" -CreateDate=`"$($created.ToString("yyyy:MM:dd HH:mm:ss"))`" -Title=`"$($status.text)`" -XPComment=`"$($status.text)`" -XPSubject=`"$($status.text)`" -overwrite_original `"$(resolve-path $outfullpath)`"")
                [void]$process.Start()
                $cmdOut = $process.StandardOutput.ReadToEnd()
                $cmdErr = $process.StandardError.ReadToEnd()
                $process.WaitForExit()
                if (![String]::IsNullOrWhiteSpace($cmdErr)) { Write-Output $cmdErr }


            }

        }

    }

} until ($response.search_metadata.next_results -eq $null -or $page -eq 10)
# stop when there are no more pages or we reach 1000 (10 pages x 100 tweets)

