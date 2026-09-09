function New-IdentPatientFormFixture {
    param([switch]$Expanded, [double]$Scale=1, [int]$OffsetX=0, [int]$OffsetY=0)
    $title=[regex]::Unescape('\u041d\u043e\u0432\u044b\u0439 \u043f\u0440\u0438\u0435\u043c - Fixture D. A. - 20 \u0441\u0435\u043d 2099 | 09:00 - 09:45')
    $rows=New-Object 'System.Collections.Generic.List[object]'
    function Row([string]$Path,[string]$Type,[string]$Id,[string]$Class,[string]$Bounds,[string]$Name='') {
        $r=ConvertTo-IdentFormRectangle $Bounds
        $boundsText=if ($null -eq $r) { '' } else {
            '{0},{1},{2},{3}' -f ([int]($r.X*$Scale)+$OffsetX),([int]($r.Y*$Scale)+$OffsetY),([int]($r.Width*$Scale)),([int]($r.Height*$Scale))
        }
        $rows.Add([pscustomobject]@{
            path=$Path; rootName=$title; name=$Name; controlType=('ControlType.'+$Type); automationId=$Id
            className=$Class; bounds=$boundsText; isEnabled=$true; isOffscreen=$false
            patterns=if ($Type -eq 'Edit') { @('ValuePatternIdentifiers.Pattern') } else { @() }
        })
    }
    Row '0' 'Window' '' 'Window' '163,66,1594,939' $title
    Row '0/1' 'Edit' '' 'TextBox' '379,175,293,34'
    Row '0/3' 'Edit' '_surnameTextBox' 'TextBox' '379,229,293,34'
    Row '0/4' 'Edit' '' 'TextBox' '379,272,293,34'
    Row '0/5' 'Edit' '' 'TextBox' '379,315,293,34'
    Row '0/6' 'Edit' 'MaskedTextBox' 'TextBox' '913,175,128,34'
    Row '0/12' 'ComboBox' '_comboBox' 'ComboBox' '915,231,32,30'
    Row '0/13' 'Edit' '' 'TextBox' '947,231,212,30'
    $panel=if ($Expanded) { '0/36' } else { '0/15' }
    Row $panel 'Pane' '' 'ScrollViewer' '1222,114,532,832'
    Row ($panel+'/3') 'Text' '_receptionTimeTextBlock' 'TextBlock' '1424,173,105,27' '09:00 - 09:45'
    Row ($panel+'/5') 'Edit' '' 'TextBox' '1237,210,502,34'
    Row ($panel+'/5/0') 'Edit' '_textBox' 'TextBox' '1237,210,502,34'
    if ($Expanded) {
        Row '0/16' 'Edit' '_textBox' 'TextBox' '379,389,293,34'
        Row '0/18' 'Edit' '_textBox' 'TextBox' '379,432,293,34'
        Row '0/23' 'Text' '' 'TextBlock' '181,546,198,23' 'E-mail'
        Row '0/24' 'Edit' '' 'TextBox' '379,538,293,34'
        Row '0/25' 'Edit' '' 'TextBox' '379,581,293,34'
        Row '0/26' 'Edit' '' 'TextBox' '379,624,293,34'
        Row '0/28' 'Edit' '_textBox' 'TextBox' '943,434,205,30'
        Row '0/28/0' 'Edit' '_textBox' 'TextBox' '943,434,205,30'
        Row '0/31' 'ComboBox' '' 'ComboBox' ''
    }
    return $rows.ToArray()
}
