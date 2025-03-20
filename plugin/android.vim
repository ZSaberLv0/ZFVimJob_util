
" params: {
"   'deviceFilter' : ['192\.168\.xx\.xx'], // (optional) list of devices (regexp) to filter
"   'apkBuild' : ['path_to_run_assembleDebug'], // (optional) list of path to build apk
"   'filePush' : [ // (optional) list of files to push
"     {
"       'from' : 'local_path',
"       'to' : 'remote_path',
"     },
"   ],
"   'httpServer' : { // (optional) start http server
"     'path' : 'xxx',
"     'port' : 'xxx',
"   },
"   'apkInstall' : ['apk_path'], // (optional) list of apks to install
"   'apkRun' : ['com.xxx.xxx/.MainActivity'], // (optional) list of apk to run
"   'apkLogFilter' : ['xxx'], // (optional) list of log filter
"   'apkRunTimeout' : 10000, // (optional) auto close apk
"   'filePull' : [ // (optional) list of files to pull
"     {
"       'from' : 'remote_path',
"       'to' : 'local_path',
"     },
"   ],
" }
"
" return: ZFAutoScript config param
function! ZFJobUtil_AndroidRun(params, ...)
    let config = get(a:, 1, {})
    let jobList = get(config, 'jobList', [])
    let config['jobList'] = jobList
    if empty(get(config, 'outputTo', {}))
        let config['outputTo'] = get(g:, 'ZFAsyncRun_outputTo', {})
    endif

    let task = {
                \   'params' : a:params,
                \   'onExitSaved' : get(config, 'onExit', {}),
                \   'deviceFilter_success' : 0,
                \   'apkLogTaskId' : -1,
                \ }
    let config['onExit'] = ZFJobFunc(function('s:onExit'), [task])

    if !empty(get(a:params, 'apkBuild', []))
        for item in a:params['apkBuild']
            call add(jobList, {
                        \   'jobCmd' : './gradlew assembleDebug',
                        \   'jobCwd' : item,
                        \ })
        endfor
    endif

    if !empty(get(a:params, 'deviceFilter', []))
        call add(jobList, {
                    \   'jobCmd' : 'adb devices',
                    \   'onExit' : ZFJobFunc(function('s:deviceFilter_onExit'), [task]),
                    \ })
        call add(jobList, {
                    \   'jobCmd' : ZFJobFunc(function('s:deviceFilter_checkTask'), [task]),
                    \ })
    endif

    if !empty(get(a:params, 'filePush', []))
        for item in a:params['filePush']
            call add(jobList, {
                        \   'jobCmd' : printf('adb push "%s" "%s"', item['from'], item['to']),
                        \ })
        endfor
    endif

    if !empty(get(a:params, 'httpServer', {}))
        call add(jobList, {
                    \   'jobCmd' : [
                    \     printf('silent! call ZFHttpServerStop(%s)', a:params['httpServer']['port']),
                    \     printf('call ZFHttpServerStart(%s, "%s")', a:params['httpServer']['port'], a:params['httpServer']['path']),
                    \   ],
                    \ })
        call add(jobList, {
                    \   'jobCmd' : 1000,
                    \ })
    endif

    if !empty(get(a:params, 'apkInstall', []))
        for item in a:params['apkInstall']
            call add(jobList, {
                        \   'jobCmd' : printf('adb install -r -d -t "%s"', item),
                        \ })
        endfor
    endif

    call add(jobList, {
                \   'jobCmd' : 'adb shell input keyevent KEYCODE_WAKEUP',
                \ })
    call add(jobList, {
                \   'jobCmd' : ZFJobFunc(function('s:apkLog_startTask'), [task]),
                \ })

    if !empty(get(a:params, 'apkRun', []))
        for item in a:params['apkRun']
            call add(jobList, {
                        \   'jobCmd' : printf('adb shell am start %s', item),
                        \ })
        endfor

        call add(jobList, {
                    \   'jobCmd' : get(a:params, 'apkRunTimeout', 10000),
                    \ })

        for item in a:params['apkRun']
            let name = strpart(item, 0, stridx(item, '/'))
            call add(jobList, {
                        \   'jobCmd' : printf('adb shell am force-stop %s', name),
                        \ })
        endfor
    endif

    if !empty(get(a:params, 'filePull', []))
        for item in a:params['filePull']
            call add(jobList, {
                        \   'jobCmd' : printf('adb pull "%s" "%s"', item['from'], item['to']),
                        \ })
        endfor
    endif

    return config
endfunction

function! s:deviceFilter_onExit(task, jobStatus, exitCode)
    let deviceFilter = get(a:task['params'], 'deviceFilter', [])
    if empty(deviceFilter)
        let a:task['deviceFilter_success'] = 1
        return
    endif
    for line in a:jobStatus['jobOutput']
        for f in deviceFilter
            if match(line, f) >= 0
                let a:task['deviceFilter_success'] = 1
                return
            endif
        endfor
    endfor
endfunction
function! s:deviceFilter_checkTask(task, jobStatus)
    if a:task['deviceFilter_success']
        return {
                    \   'exitCode' : '0',
                    \ }
    else
        return {
                    \   'exitCode' : '-1',
                    \   'output' : 'no suitable device found',
                    \ }
    endif
endfunction

function! s:apkLogFilter_onOutputFilter(task, jobStatus, textList, type)
    let apkLogFilter = get(a:task['params'], 'apkLogFilter', [])
    if empty(apkLogFilter)
        return
    endif

    let i = len(a:textList)
    while i > 0
        let i -= 1
        let text = a:textList[i]
        let match = 0
        for f in apkLogFilter
            if match(text, f) >= 0
                let match = 1
                break
            endif
        endfor
        if !match
            call remove(a:textList, i)
        endif
    endwhile
endfunction
function! s:apkLog_onOutput(task, ownerJobStatus, jobStatus, textList, type)
    if !empty(a:textList)
        call extend(a:ownerJobStatus['jobOutput'], a:textList)
        call ZFJobOutput(a:ownerJobStatus, a:textList, a:type)
    endif
endfunction
function! s:apkLog_startTask(task, jobStatus)
    let a:task['apkLogTaskId'] = ZFGroupJobStart({
                \   'jobList' : [
                \     {
                \       'jobCmd' : 'adb logcat -c',
                \     },
                \     {
                \       'jobCmd' : 'adb logcat',
                \       'onOutputFilter' : ZFJobFunc(function('s:apkLogFilter_onOutputFilter'), [a:task]),
                \       'onOutput' : ZFJobFunc(function('s:apkLog_onOutput'), [a:task, ZFGroupJobStatus(a:jobStatus['jobImplData']['groupJobId'])]),
                \     },
                \   ],
                \ })
    return {
                \   'exitCode' : '0',
                \ }
endfunction

function! s:onExit(task, jobStatus, exitCode)
    call ZFGroupJobStop(a:task['apkLogTaskId'])
    let a:task['apkLogTaskId'] = -1

    if !empty(get(a:task['params'], 'httpServer', {}))
        try
            silent! execute printf('call ZFHttpServerStop(%s)'
                        \ , a:task['params']['httpServer']['port']
                        \ )
        catch
        endtry
    endif

    let Fn_onExit = get(a:task, 'onExitSaved', {})
    if !empty(Fn_onExit)
        call ZFJobFuncCall(Fn_onExit, [a:jobStatus, a:exitCode])
    endif
endfunction

