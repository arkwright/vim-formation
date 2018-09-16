" TODO
"  - Don't open files that don't exist!
"  - Move cursor to window containing original file (cursor position should be preserved)

" Can do the greedy matching with:
" echo matchlist('src/app/abc/def/component.js', '\vsrc/app/(.+)/component.js')

" Can get all window (split) names and numbers with this:
" map(range(1, winnr('$')), '[v:val, bufname(winbufnr(v:val))]')

" Check if file is readable with
" filereadable(l:containerFilePath)

function! s:pluck(dictionary, property)
  let l:pluckedValues = []

  for l:value in values(a:dictionary)
    call add(l:pluckedValues, l:value[a:property])
  endfor

  return l:pluckedValues
endfunction

function! s:findMatchingFormationAndFile(config, filePath)
  for l:formationName in keys(a:config)
    for l:file in a:config[l:formationName]['files']
      let l:fileName = l:file['name']
      let l:location = l:file['location']
      let l:locationTokens = s:extractTokens(l:location)
      let l:locationRegex = s:convertLocationToRegex(l:location, l:locationTokens)
      let l:matches = matchlist(a:filePath, '\v' . l:locationRegex)

      if len(l:matches) ==# 0
        continue
      endif

      let l:tokenValues = filter(l:matches, 'v:val !=# ""')

      if len(l:tokenValues) > 0
        call remove(l:tokenValues, 0)
      endif

      let l:tokensAndValues = s:mapTokensToValues(l:locationTokens, l:tokenValues)
      let l:variablesAndValues = s:mapFileVariablesToValues(l:file)
      let l:mergedVariablesAndValues = extend(l:tokensAndValues, l:variablesAndValues)

      return {
\       "formation": a:config[l:formationName],
\       "file": l:file,
\       "variables": l:mergedVariablesAndValues,
\     }
    endfor
  endfor

  return {}
endfunction

function! s:extractTokens(location)
  let l:characters = split(a:location, '\zs')
  let l:tokens = []
  let l:withinToken = 0
  let l:tokenText = ''

  for l:character in l:characters
    if l:withinToken ==# 0
      if l:character ==# '{'
        let l:withinToken = 1
        let l:tokenText = l:character
      endif
    else
      let l:tokenText = l:tokenText . l:character

      if l:character ==# '}'
        let l:withinToken = 0
        call add(l:tokens, l:tokenText)
      endif
    endif
  endfor

  return l:tokens
endfunction

function! s:convertLocationToRegex(location, tokens)
  let l:regex = a:location

  for l:token in a:tokens
    let l:regex = substitute(l:regex, '\V' . l:token, '(.+)', '')
  endfor

  return l:regex
endfunction

function! s:mapTokensToValues(tokens, tokenValues)
  let l:tokensAndValues = {}

  if len(a:tokens) !=# len(a:tokenValues)
    throw 'vim-formation: mapTokensToValues(): tokens and tokenValues must be the same length!'
  endif

  let l:index = 0

  for l:token in a:tokens
    let l:tokensAndValues[l:token] = a:tokenValues[l:index]
    let l:index = l:index + 1
  endfor

  return l:tokensAndValues
endfunction

function! s:mapFileVariablesToValues(file)
  if (has_key(a:file, 'variables') ==# 0)
    return {}
  endif

  let l:variables = a:file['variables']
  let l:variablesAndValues = {}

  for [l:variableName, l:variableValue] in items(l:variables)
    if l:variableValue ==# '{$parentDirectory}'
      let l:variablesAndValues[l:variableName] = expand('%:h:t')
    else
      let l:variablesAndValues[l:variableName] = l:variableValue
    endif
  endfor

  return l:variablesAndValues
endfunction

function! s:enhanceFilesWithReconstructedLocations(files, variables)
  let l:enhancedFiles = {}

  for l:file in a:files
    let l:fileName = l:file['name']
    let l:reconstructedLocation = l:file['location']

    for [l:variableName, l:variableValue] in items(a:variables)
      let l:reconstructedLocation = substitute(l:reconstructedLocation, '\V' . l:variableName, l:variableValue, 'g')
    endfor

    let l:enhancedFiles[l:fileName] = extend({}, l:file)
    let l:enhancedFiles[l:fileName]['reconstructedLocation'] = l:reconstructedLocation
  endfor

  return l:enhancedFiles
endfunction

function! s:getWindowFileLocations()
  return map(range(1, winnr('$')), 'bufname(winbufnr(v:val))')
endfunction

function! s:getReconstructedFileLocationsToOpen(formation, filesWithReconstructedLocations, targetName)
  let l:fileNamesToOpen = []

  if has_key(a:filesWithReconstructedLocations, a:targetName)
    let l:fileNamesToOpen = [a:targetName]
  endif

  if has_key(a:formation, 'collections') ==# 1
    for [l:collectionName, l:collectionFileNames] in items(a:formation['collections'])
      if l:collectionName ==# a:targetName
        let l:fileNamesToOpen = l:collectionFileNames
        break
      endif
    endfor
  endif

  let l:reconstructedFileLocationsToOpen = []

  for l:fileName in l:fileNamesToOpen
    call add(l:reconstructedFileLocationsToOpen, a:filesWithReconstructedLocations[l:fileName]['reconstructedLocation'])
  endfor

  return l:reconstructedFileLocationsToOpen
endfunction

function! s:groupWindowFileLocationsByAffiliation(windowFileLocations, filesByName)
  let l:groupedWindowFileLocations = {
\   "unaffiliatedBeginning": [],
\   "formation": [],
\   "unaffiliatedEnd": [],
\ }

  let l:formationFileLocations = s:pluck(a:filesByName, 'reconstructedLocation')

  let l:foundFirstFormationFile = 0

  for l:windowFileLocation in a:windowFileLocations
    if index(l:formationFileLocations, l:windowFileLocation) > -1
      call add(l:groupedWindowFileLocations['formation'], l:windowFileLocation)
      let l:foundFirstFormationFile = 1
      continue
    endif

    if l:foundFirstFormationFile ==# 0
      call add(l:groupedWindowFileLocations['unaffiliatedBeginning'], l:windowFileLocation)
    else
      call add(l:groupedWindowFileLocations['unaffiliatedEnd'], l:windowFileLocation)
    endif
  endfor

  return l:groupedWindowFileLocations
endfunction

function! s:positionFileLocations(filesByName, fileLocationsToPosition)
  let l:files = values(a:filesByName)

  call sort(l:files, {file1, file2 -> file1['position'] ==# file2['position'] ? 0 : file1['position'] > file2['position'] ? 1 : -1})
  call filter(l:files, {index, file -> index(a:fileLocationsToPosition, file['reconstructedLocation']) ==# -1 ? 0 : 1})
  call map(l:files, {index, file -> file['reconstructedLocation']})

  return l:files
endfunction

function! s:arrangeWindows(windowLocations)
  let l:readableWindowLocations = filter(copy(a:windowLocations), {index, location -> filereadable(location)})

  if len(l:readableWindowLocations) ==# 0
    return
  endif

  let l:originalWindowBufferNumber = winbufnr('$')

  only
  execute 'edit ' . l:readableWindowLocations[0]

  if len(l:readableWindowLocations) ==# 1
    return
  endif

  for l:location in remove(l:readableWindowLocations, 1, -1)
    if g:formationSplitType ==# 'horizontal'
      execute 'rightbelow split ' . l:location
    else
      execute 'rightbelow vsplit ' . l:location
    endif
  endfor

  " Move to window containing buffer which we began on.
  " Preserves original cursor location for the user.
  let l:originalBufferWindowIds = win_findbuf(l:originalWindowBufferNumber)

  if len(l:originalBufferWindowIds) ==# 0
    return
  endif

  let l:originalBufferWindowNumber = win_id2tabwin(l:originalBufferWindowIds[0])[1]

  execute l:originalBufferWindowNumber . 'wincmd w'
endfunction

function! s:deployFormation(formation, targetName, variables)
  let l:filesByNameWithReconstructedLocations = s:enhanceFilesWithReconstructedLocations(a:formation['files'], a:variables)
  let l:windowFileLocations = s:getWindowFileLocations()
  let l:formationFileLocationsToOpen = s:getReconstructedFileLocationsToOpen(a:formation, l:filesByNameWithReconstructedLocations, a:targetName)
  let l:groupedWindowFileLocations = s:groupWindowFileLocationsByAffiliation(l:windowFileLocations, l:filesByNameWithReconstructedLocations)
  let l:formationDesiredFileLocations = uniq(sort(extend(extend([], l:groupedWindowFileLocations['formation']), l:formationFileLocationsToOpen)))
  let l:positionedFormationDesiredFileLocations = s:positionFileLocations(l:filesByNameWithReconstructedLocations, l:formationDesiredFileLocations)
  let l:revisedWindowLocations = l:groupedWindowFileLocations['unaffiliatedBeginning'] + l:positionedFormationDesiredFileLocations + l:groupedWindowFileLocations['unaffiliatedEnd']

  call s:arrangeWindows(l:revisedWindowLocations)
endfunction

" Open the complementary file.
function! s:formation(targetName)
  " TODO: Gracefully handle any absence of config file
  let l:configFilePath = getcwd() . '/.formation.json'
  let l:config = JSON#parse(join(readfile(l:configFilePath), ''))

  let l:currentFilePath = expand('%')

  let l:match = s:findMatchingFormationAndFile(l:config, l:currentFilePath)

  if has_key(l:match, 'formation') ==# 0
    return
  endif

  call s:deployFormation(l:match['formation'], a:targetName, l:match['variables'])
endfunction

" Allow the user to specify the command name which will invoke Formation.
" Fallback to a default value if nothing is specified.
if exists("g:formationCommandName") ==# 0 || g:formationCommandName ==# ''
  let g:formationCommandName = "Formation"
endif

" Dynamically create the Formation invocation command, unless an identically
" named command already exists.
if exists(":" . g:formationCommandName) ==# 0
  execute "command! -nargs=1 " . g:formationCommandName . " call s:formation(<f-args>)"
endif
