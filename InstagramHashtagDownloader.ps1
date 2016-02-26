#Requires -version 3.0

###############################################################################
# This is a quick and dirty way to download copies of instagram photos with a
# particular hashtag. It uses the iconosquare.com rss tagfeed feature to query
# an rss feed of a particular hashtags photos. I'm not sure what, if any,
# limitations exist on those feeds. Will eventually convert this to use the
# official Instragram API.
###############################################################################

param(
    [Parameter(Mandatory=$True,Position=1, HelpMessage="Hashtag to download images for.")]
    [string]$hashtag,
    [Parameter(Mandatory=$True,Position=2, HelpMessage="Folder path for saving downloaded images.")]
    [string]$outpath,
    [Parameter(Position=3, HelpMessage="Path to ExifTool.exe")]
    [string]$ExifToolPath
)

# remove the hashtag character if it was included
if ($hashtag[0] -eq '#') { $hashtag = $hashtag.Substring(1) }

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

# grab the feed
[xml]$feed = Invoke-WebRequest "http://iconosquare.com/tagFeed/$hashtag"

$items = $feed.rss.channel.item | 
    select author,
        @{L="title";E={$_.title.innertext}},
        @{L="pubdate";E={get-date $_.pubdate}},
        @{L="imgsrc";E={[xml]$html = $_.description.innertext; $html.a.img.src}}

foreach ($i in $items) {

    $outfile = "$($i.pubdate.ToUniversalTime().ToString("yyyyMMdd_HHmmss'Z'"))_$($i.author).jpg"
    $outfullpath = join-path $outpath $outfile

    if (test-path $outfullpath) { write-output "skipping duplicate: $($i.imgsrc.Substring($i.imgsrc.LastIndexOf('/')+1))"; continue }

    # download the image
    write-output "Downloading $outfile"
    Invoke-WebRequest $i.imgsrc -OutFile $outfullpath

    # write metadata if we have exiftool available
    if ($ExifToolFound -eq $true) {

        $psi.Arguments = @("-Artist=`"$($i.author)`" -CreateDate=`"$($i.pubdate.ToString("yyyy:MM:dd HH:mm:ss"))`" -Title=`"$($i.title)`" -XPComment=`"$($i.title)`" -XPSubject=`"$($i.title)`" -overwrite_original `"$(resolve-path $outfullpath)`"")
        [void]$process.Start()
        $cmdOut = $process.StandardOutput.ReadToEnd()
        $cmdErr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if (![String]::IsNullOrWhiteSpace($cmdErr)) { Write-Output $cmdErr }
    }
    
}