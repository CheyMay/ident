function New-IdentCalendarFixture {
    # Geometry recovered from the clinic's 56-descendant grid capture; all captions/dates below are synthetic.
    # The original capture omitted visibility flags, so these flags are test assumptions, not observed evidence.
    $rows=[Collections.Generic.List[object]]::new()
    $add={ param($path,$name,$bounds,$id='',$class='TextBlock',$type='ControlType.Text')
        $rows.Add([pscustomobject]@{ path=$path; rootName=''; name=$name; bounds=$bounds; automationId=$id;
            className=$class; controlType=$type; isEnabled=$true; isOffscreen=$false; patterns=@('SynchronizedInputPatternIdentifiers.Pattern') })
    }
    & $add '0' '' '514,153,1406,855' 'cttGrid' 'TimeTableGridControl' 'ControlType.Custom'
    & $add '0/0' '20.09.2099' '592,167,719,23'
    & $add '0/1' 'Chair A' '592,217,233,23'
    & $add '0/2' 'Chair B' '835,217,233,23'
    & $add '0/3' 'Chair C' '1078,217,233,23'
    & $add '0/4' 'Doctor A' '592,267,233,23'
    & $add '0/5' 'Doctor D' '592,767,233,22'
    & $add '0/6' 'Doctor B' '835,267,233,23'
    & $add '0/7' 'Doctor E' '835,767,233,22'
    & $add '0/8' 'Doctor C' '1078,267,233,23'
    & $add '0/9' 'Doctor F' '1078,767,233,22'
    for($i=0;$i -lt 20;$i++) {
        $time=([timespan]::FromMinutes(540+30*$i)).ToString('hh\:mm')
        $y=313+45*$i
        if ($i -ge 10) { $y+=50 }
        & $add ('0/'+(10+2*$i)) $time ('538,'+$y+',44,25')
        & $add ('0/'+(11+2*$i)) $time ('1321,'+$y+',44,25')
    }
    & $add '0/50' '' '1892,153,28,843' 'VerticalScrollBar' 'ScrollBar' 'ControlType.ScrollBar'
    & $add '0/50/0' '' '1892,153,28,23' 'LineUp' 'RepeatButton' 'ControlType.Button'
    & $add '0/50/1' '' '' 'PageUp' 'RepeatButton' 'ControlType.Button'
    & $add '0/50/2' '' '1899,787,14,187' 'PageDown' 'RepeatButton' 'ControlType.Button'
    & $add '0/50/3' '' '1899,176,14,611' '' 'Thumb' 'ControlType.Thumb'
    & $add '0/50/4' '' '1892,974,28,22' 'LineDown' 'RepeatButton' 'ControlType.Button'
    return $rows.ToArray()
}
