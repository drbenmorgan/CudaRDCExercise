#----------------------------------*-CMake-*----------------------------------#
# Copyright 2020 UT-Battelle, LLC and other Celeritas Developers.
# See the top-level COPYRIGHT file for details.
# SPDX-License-Identifier: (Apache-2.0 OR MIT)
#[=======================================================================[.rst:

CudaRdcUtils
--------------

CMake utility functions for building and linking libraries containing CUDA
relocatable device code.

.. command:: cuda_rdc_add_library

  Add a library to the project using the specified source files *with* special handling
  for the case where the library contains CUDA relocatable device code.

  ::

    cuda_rdc_add_library(<name> [STATIC | SHARED | MODULE]
            [EXCLUDE_FROM_ALL]
            [<source>...])

  To support CUDA relocatable device code, the following 4 targets will be constructed:

  - A object library used to compile the source code and share the result with the static and shared library
  - A static library used as input to ``nvcc -dlink``
  - A shared “intermediary” library containing all the ``.o`` files but NO ``nvcc -dlink`` result
  - A shared “final” library containing the result of ``nvcc -dlink`` and linked against the "intermediary" shared library.

  An executable needs to load exactly one result of ``nvcc -dlink`` whose input needs to be
  the ``.o`` files from all the CUDA libraries it uses/depends-on. So if the executable has CUDA code,
  it will call ``nvcc -dlink`` itself and link against the "intermediary" shared libraries.
  If the executable has no CUDA code, then it needs to link against the "final" library
  (of its most derived dependency). If the executable has no CUDA code but uses more than one
  CUDA library, it will still need to run its own ``nvcc -dlink`` step.


.. command:: cuda_rdc_target_link_libraries

  Specify libraries or flags to use when linking a given target and/or its dependents, taking
  in account the extra targets (see cuda_rdc_add_library) needed to support CUDA relocatable
  device code. 

    ::

      cuda_rdc_target_link_libraries(<target>
        <PRIVATE|PUBLIC|INTERFACE> <item>...
        [<PRIVATE|PUBLIC|INTERFACE> <item>...]...))

  Usage requirements from linked library targets will be propagated to all four targets. Usage requirements
  of a target's dependencies affect compilation of its own sources. In the case that ``<target>`` does
  not contain CUDA code, the command decays to ``target_link_libraries``.

  See ``target_link_libraries`` for additional detail.


.. command:: cuda_rdc_target_include_directories
  
  Add include directories to a target.

    ::

      cuda_rdc_target_include_directories(<target> [SYSTEM] [AFTER|BEFORE]
        <INTERFACE|PUBLIC|PRIVATE> [items1...]
        [<INTERFACE|PUBLIC|PRIVATE> [items2...] ...])

  Specifies include directories to use when compiling a given target. The named <target> 
  must have been created by a command such as cuda_rdc_add_library(), add_executable() or add_library(),
  and can be used with an ALIAS target. It is aware of the 4 underlying targets (objects, static, 
  middle, final) present when the input target was created cuda_rdc_add_library() and will propagate
  the include directories to all four. In the case that ``<target>`` does not contain CUDA code,
  the command decays to ``target_include_directories``.

  See ``target_include_directories`` for additional detail.


.. command:: cuda_rdc_install

  Specify installation rules for a CUDA RDC target.

    ::
      cuda_rdc_install(TARGETS targets... <ARGN>)

  In the case that an input target does not contain CUDA code, the command decays
  to ``install``.
  
  See ``install`` for additional detail.
  
#]=======================================================================]

define_property(TARGET PROPERTY CUDA_RDC_LIBRARY_TYPE
  BRIEF_DOCS "Indicate the type of cuda library (STATIC and SHARED for nvlink usage, FINAL for linking into not cuda library/executable"
  FULL_DOCS "Indicate the type of cuda library (STATIC and SHARED for nvlink usage, FINAL for linking into not cuda library/executable"
)
define_property(TARGET PROPERTY CUDA_RDC_FINAL_LIBRARY
  BRIEF_DOCS "Name of the final library corresponding to this cuda library"
  FULL_DOCS "Name of the final library corresponding to this cuda library"
)
define_property(TARGET PROPERTY CUDA_RDC_STATIC_LIBRARY
  BRIEF_DOCS "Name of the static library corresponding to this cuda library"
  FULL_DOCS "Name of the static library corresponding to this cuda library"
)
define_property(TARGET PROPERTY CUDA_RDC_MIDDLE_LIBRARY
  BRIEF_DOCS "Name of the shared (without nvlink step) library corresponding to this cuda library"
  FULL_DOCS "Name of the shared (without nvlink step) library corresponding to this cuda library"
)
define_property(TARGET PROPERTY CUDA_RDC_OBJECT_LIBRARY
  BRIEF_DOCS "Name of the object (without nvlink step) library corresponding to this cuda library"
  FULL_DOCS "Name of the object (without nvlink step) library corresponding to this cuda library"
)

##############################################################################
# Separate the OPTIONS out from the sources
#
macro(CUDA_GET_SOURCES_AND_OPTIONS _sources _cmake_options _options)
  set( ${_sources} )
  set( ${_cmake_options} )
  set( ${_options} )
  set( _found_options FALSE )
  foreach(arg ${ARGN})
    if("x${arg}" STREQUAL "xOPTIONS")
      set( _found_options TRUE )
    elseif(
        "x${arg}" STREQUAL "xWIN32" OR
        "x${arg}" STREQUAL "xMACOSX_BUNDLE" OR
        "x${arg}" STREQUAL "xEXCLUDE_FROM_ALL" OR
        "x${arg}" STREQUAL "xSTATIC" OR
        "x${arg}" STREQUAL "xSHARED" OR
        "x${arg}" STREQUAL "xMODULE"
        )
      list(APPEND ${_cmake_options} ${arg})
    else()
      if ( _found_options )
        list(APPEND ${_options} ${arg})
      else()
        # Assume this is a file
        list(APPEND ${_sources} ${arg})
      endif()
    endif()
  endforeach()
endmacro()

#
# Internal routine to figure out if a list contains
# CUDA source code.  Returns TRUE/FALSE in the OUTPUT_VARIABLE
#
function(cuda_rdc_sources_contains_cuda OUTPUT_VARIABLE)
  set(_contains_cuda FALSE)
  foreach(_source ${ARGN})
    get_source_file_property(_iscudafile ${_source} LANGUAGE)
    if(_iscudafile)
      if ("x${_iscudafile}" STREQUAL "xCUDA")
        set(_contains_cuda TRUE)
      endif()
    else()
      get_filename_component(_ext "${_source}" LAST_EXT)
      if("${_ext}" STREQUAL ".cu")
        set(_contains_cuda TRUE)
        break()
      endif()
    endif()
  endforeach()
  set(${OUTPUT_VARIABLE} ${_contains_cuda} PARENT_SCOPE)
endfunction()

#
# Internal routine to figure out if a target already contains
# CUDA source code.  Returns TRUE/FALSE in the OUTPUT_VARIABLE
#
function(cuda_rdc_lib_contains_cuda OUTPUT_VARIABLE target)
  cuda_rdc_strip_alias(target ${target})

  get_target_property(_targettype ${target} CUDA_RDC_LIBRARY_TYPE)
  if(_targettype)
    # The target is one of the components of a library with CUDA separatable code,
    # no need to check the source files.
    set(${OUTPUT_VARIABLE} TRUE PARENT_SCOPE)
  else()
    get_target_property(_target_sources ${target} SOURCES)
    cuda_rdc_sources_contains_cuda(_contains_cuda ${_target_sources})
    set(${OUTPUT_VARIABLE} ${_contains_cuda} PARENT_SCOPE)
  endif()
endfunction()

#
# Generate an empty .cu file to transform the library to a CUDA library
#
function(cuda_rdc_generate_empty_cu_file emptyfilenamevar target)
  set(_stub "${CMAKE_CURRENT_BINARY_DIR}${CMAKE_FILES_DIRECTORY}/${target}_emptyfile.cu")
  if(NOT EXISTS ${_stub})
    file(WRITE "${_stub}" "/* intentionally empty. */")
  endif()
  set(${emptyfilenamevar} ${_stub} PARENT_SCOPE)
endfunction()

#
# Transfer the setting \${what} (both the PUBLIC and INTERFACE version) to from library \${fromlib} to the library \${tolib} that depends on it

function(cuda_rdc_transfer_setting fromlib tolib what)
  get_target_property(_temp ${fromlib} ${what})
  if (_temp)
    cmake_language(CALL target_${what} ${tolib} PUBLIC ${_temp})
  endif()
  get_target_property(_temp ${fromlib} INTERFACE_${what})
  if (_temp)
    cmake_language(CALL target_${what} ${tolib} PUBLIC ${_temp})
  endif()
endfunction()

#
# cuda_rdc_add_library
#
# Add a library taking into account whether it contains
# or depends on separatable CUDA code.  If it contains
# cuda code, it will be marked as "separatable compilation"
# (i.e. request "Relocatable device code")
#
function(cuda_rdc_add_library target)

  CUDA_GET_SOURCES_AND_OPTIONS(_sources _cmake_options _options ${ARGN})

  set(_midsuf "")
  set(_staticsuf "_static")
  cuda_rdc_sources_contains_cuda(_contains_cuda ${_sources})

  # Whether we need the special code or not is actually dependent on information
  # we don't have ... yet
  # - whether the user request CUDA_SEPARABLE_COMPILATION
  # - whether the library depends on a library with CUDA_SEPARABLE_COMPILATION code.
  # I.e. this should really be done at generation time.
  # So in the meantime we use rely on the user to call this routine
  # only in the case where they want the CUDA device code to be compiled
  # as "relocatable device code"

  if(NOT CMAKE_CUDA_COMPILER OR NOT _contains_cuda)
    add_library(${target} ${ARGN})
    return()
  endif()

  cmake_parse_arguments(_ADDLIB_PARSE
    "STATIC;SHARED;MODULE"
    ""
    ""
    ${ARGN}
  )
  set(_lib_requested_type "SHARED")
  set(_cudaruntime_requested_type "Shared")
  set(__static_build FALSE)
  if((NOT BUILD_SHARED_LIBS AND NOT _ADDLIB_PARSE_SHARED) OR _ADDLIB_PARSE_STATIC)
    set(_lib_requested_type "STATIC")
    set(_cudaruntime_requested_type "Static")
    set(_staticsuf "${_midsuf}")
    set(__static_build TRUE)
  endif()
  if(_ADDLIB_PARSE_MODULE) # If we are here _contains_cuda is true
    message(FATAL_ERROR "cuda_rdc_add_library does not support MODULE library containing CUDA code")
  endif()

  add_library(${target}_objects OBJECT ${_ADDLIB_PARSE_UNPARSED_ARGUMENTS})
  if(NOT __static_build)
    add_library(${target}${_staticsuf} STATIC $<TARGET_OBJECTS:${target}_objects>)
  endif()
  add_library(${target}${_midsuf} ${_lib_requested_type} $<TARGET_OBJECTS:${target}_objects>)
  # We need to use a dummy file as a library (per cmake) needs to contains
  # at least one source file.  The real content of the library will be
  # the cmake_device_link.o resulting from the execution of `nvcc -dlink`
  # Also non-cuda related test, for example `gtest_detail_Macros`,
  # will need to be linked again libcuda_rdc_final while a library
  # that the detends on and that uses Celeritas::Core (for example
  # libCeleritasTest.so) will need to be linked against `libcuda_rdc${_midsuf}`.
  # If both the `${_midsuf}` and `_final` contains the `.o` files we would
  # then have duplicated symbols (Here the symptoms will a crash
  # during the cuda library initialization rather than a link error).
  cuda_rdc_generate_empty_cu_file(_emptyfilename ${target})
  add_library(${target}_final ${_lib_requested_type}  ${_emptyfilename} )

  set_target_properties(${target}_objects PROPERTIES
    # This probably should be left to the user to set.
    # In cuda_rdc this is needed for the shared build
    # and for the static build with ROOT enabled.
    POSITION_INDEPENDENT_CODE ON
    CUDA_SEPARABLE_COMPILATION ON
    CUDA_RUNTIME_LIBRARY ${_cudaruntime_requested_type}
  )

  set_target_properties(${target}${_midsuf} PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    CUDA_SEPARABLE_COMPILATION ON
    CUDA_RUNTIME_LIBRARY ${_cudaruntime_requested_type}
    CUDA_RESOLVE_DEVICE_SYMBOLS OFF # We really don't want nvlink called.
    CUDA_RDC_LIBRARY_TYPE Shared
    CUDA_RDC_FINAL_LIBRARY ${target}_final
    CUDA_RDC_MIDDLE_LIBRARY ${target}${_midsuf}
    CUDA_RDC_STATIC_LIBRARY ${target}${_staticsuf}
    CUDA_RDC_OBJECT_LIBRARY ${target}_objects
    EXPORT_PROPERTIES "CUDA_RDC_LIBRARY_TYPE;CUDA_RDC_FINAL_LIBRARY;CUDA_RDC_MIDDLE_LIBRARY;CUDA_RDC_STATIC_LIBRARY"
  )

  if(NOT _static_build)
    set_target_properties(${target}${_staticsuf} PROPERTIES
      LINKER_LANGUAGE CUDA
      CUDA_SEPARABLE_COMPILATION ON
      CUDA_RUNTIME_LIBRARY ${_cudaruntime_requested_type}
      # CUDA_RESOLVE_DEVICE_SYMBOLS OFF # Default for static library
      CUDA_RDC_LIBRARY_TYPE Static
      CUDA_RDC_FINAL_LIBRARY ${target}_final
      CUDA_RDC_MIDDLE_LIBRARY ${target}${_midsuf}
      CUDA_RDC_STATIC_LIBRARY ${target}${_staticsuf}
      CUDA_RDC_OBJECT_LIBRARY ${target}_objects
      EXPORT_PROPERTIES "CUDA_RDC_LIBRARY_TYPE;CUDA_RDC_FINAL_LIBRARY;CUDA_RDC_MIDDLE_LIBRARY;CUDA_RDC_STATIC_LIBRARY"
    )
  endif()

  set_target_properties(${target}_final PROPERTIES
    LINKER_LANGUAGE CUDA
    CUDA_RESOLVE_DEVICE_SYMBOLS ON
    CUDA_SEPARABLE_COMPILATION ON
    CUDA_RUNTIME_LIBRARY ${_cudaruntime_requested_type}
    # CUDA_RESOLVE_DEVICE_SYMBOLS ON # Default for shared library
    CUDA_RDC_LIBRARY_TYPE Final
    CUDA_RDC_FINAL_LIBRARY ${target}_final
    CUDA_RDC_STATIC_LIBRARY ${target}${_staticsuf}
    CUDA_RDC_MIDDLE_LIBRARY ${target}${_midsuf}
    CUDA_RDC_OBJECT_LIBRARY ${target}_objects
    EXPORT_PROPERTIES "CUDA_RDC_LIBRARY_TYPE;CUDA_RDC_FINAL_LIBRARY;CUDA_RDC_MIDDLE_LIBRARY;CUDA_RDC_STATIC_LIBRARY"
  )

  target_link_libraries(${target}_final
    PUBLIC ${target}${_midsuf}
  )

  target_link_options(${target}_final
    PRIVATE
    $<DEVICE_LINK:$<TARGET_FILE:${target}${_staticsuf}>>
  )

  add_dependencies(${target}_final ${target}${_midsuf})
  add_dependencies(${target}_final ${target}${_staticsuf})

  if(_midsuf)
    add_library(${target} ALIAS ${target}${_midsuf})
  endif()
endfunction()

# Replacement for target_include_directories that is aware of
# the 4 libraries (objects, static, middle, final) libraries needed
# for a separatable CUDA library
function(cuda_rdc_target_include_directories target)
  if(NOT CMAKE_CUDA_COMPILER)
    target_include_directories(${ARGV})
  else()

    cuda_rdc_strip_alias(target ${target})
    cuda_rdc_lib_contains_cuda(_contains_cuda ${target})

    if (_contains_cuda)
      get_target_property(_targettype ${target} CUDA_RDC_LIBRARY_TYPE)
      if(_targettype)
        get_target_property(_target_middle ${target} CUDA_RDC_MIDDLE_LIBRARY)
        get_target_property(_target_object ${target} CUDA_RDC_OBJECT_LIBRARY)
      endif()
    endif()
    if(_target_object)
      target_include_directories(${_target_object} ${ARGN})
    endif()
    if(_target_middle)
      target_include_directories(${_target_middle} ${ARGN})
    else()
      target_include_directories(${ARGV})
    endif()
  endif()

endfunction()

#
# Replacement for the install function that is aware of the 3 libraries
# (static, middle, final) libraries needed for a separatable CUDA library
#
function(cuda_rdc_install subcommand firstarg)
  if(NOT "x${subcommand}" STREQUAL "xTARGETS" OR NOT TARGET ${firstarg})
    install(${ARGV})
  else()
    set(_targets ${firstarg})
    list(POP_FRONT ARGN _next)
    while(TARGET ${_next})
      list(APPEND _targets ${_next})
      list(POP_FRONT ${ARGN} _next)
    endwhile()
    # At this point all targets are in ${_targets} and ${_next} is the first non target and ${ARGN} is the rest.
    foreach(_toinstall ${_targets})
      cuda_rdc_strip_alias(_prop_target ${_toinstall})
      get_target_property(_lib_target_type ${_prop_target} TYPE)
      if(NOT "x${_lib_target_type}" STREQUAL "xINTERFACE_LIBRARY")
        get_target_property(_targettype ${_prop_target} CUDA_RDC_LIBRARY_TYPE)
        if(_targettype)
          get_target_property(_target_final ${_prop_target} CUDA_RDC_FINAL_LIBRARY)
          get_target_property(_target_middle ${_prop_target} CUDA_RDC_MIDDLE_LIBRARY)
          get_target_property(_target_static ${_prop_target} CUDA_RDC_STATIC_LIBRARY)
          set(_toinstall ${_target_final} ${_target_middle} ${_target_static})
        endif()
      endif()
      install(TARGETS ${_toinstall} ${_next} ${ARGN})
    endforeach()
  endif()
endfunction()

# Return TRUE if 'lib' depends/uses directly or indirectly the library `potentialdepend`
function(cuda_rdc_depends_on OUTVARNAME lib potentialdepend)
  set(${OUTVARNAME} FALSE PARENT_SCOPE)
  if(TARGET ${lib} AND TARGET ${potentialdepend})
    set(lib_link_libraries "")
    get_target_property(_lib_target_type ${lib} TYPE)
    if(NOT "x${_lib_target_type}" STREQUAL "xINTERFACE_LIBRARY")
      get_target_property(lib_link_libraries ${lib} LINK_LIBRARIES)
    endif()
    foreach(linklib ${lib_link_libraries})
      if("${linklib}" STREQUAL "${potentialdepend}")
        set(${OUTVARNAME} TRUE PARENT_SCOPE)
        return()
      endif()
      cuda_rdc_depends_on(${OUTVARNAME} ${linklib} ${potentialdepend})
      if(${OUTVARNAME})
        set(${OUTVARNAME} ${${OUTVARNAME}} PARENT_SCOPE)
        return()
      endif()
    endforeach()
  endif()
endfunction()


# Return the 'real' target name whether the output is an alias or not.
function(cuda_rdc_strip_alias OUTVAR target)
  if(TARGET ${target})
    get_target_property(_target_alias ${target} ALIASED_TARGET)
  endif()
  if(TARGET ${_target_alias})
    set(target ${_target_alias})
  endif()
  set(${OUTVAR} ${target} PARENT_SCOPE)
endfunction()

# Return the middle/shared library of the target, if any.
macro(cuda_rdc_get_library_middle_target outvar target)
  get_target_property(_target_type ${target} TYPE)
  if(NOT "x${_target_type}" STREQUAL "xINTERFACE_LIBRARY")
    get_target_property(${outvar} ${target} CUDA_RDC_MIDDLE_LIBRARY)
  else()
    set(${outvar} ${target})
  endif()
endmacro()

# Retrieve the "middle" library, i.e. given a target, the
# target name to be used as input to the linker of dependent libraries.
function(cuda_rdc_use_middle_lib_in_property target property)
  get_target_property(_target_libs ${target} ${property})

  set(_new_values)
  foreach(_lib ${_target_libs})
    set(_newlib ${_lib})
    if(TARGET ${_lib})
      cuda_rdc_strip_alias(_lib ${_lib})
      cuda_rdc_get_library_middle_target(_libmid ${_lib})
      if(_libmid)
        set(_newlib ${_libmid})
      endif()
    endif()
    list(APPEND _new_values ${_newlib})
  endforeach()

  if(_new_values)
    set_target_properties(${target} PROPERTIES
      ${property} "${_new_values}"
    )
  endif()
endfunction()

# Return the most derived "separatable cuda" library the target depends on.
# If two or more cuda library are independent, we return both and the calling executable
# should be linked with nvcc -dlink.
function(cuda_rdc_find_final_library OUTLIST flat_dependency_list)
  set(_result "")
  foreach(_lib ${flat_dependency_list})
    if(NOT _result)
      list(APPEND _result ${_lib})
    else()
      set(_newresult "")
      foreach(_reslib ${_result})
        cuda_rdc_depends_on(_depends_on ${_lib} ${_reslib})
        cuda_rdc_depends_on(_depends_on ${_reslib} ${_lib})

        cuda_rdc_depends_on(_depends_on ${_reslib} ${_lib})
        if(${_depends_on})
          # The library in the result depends/uses the library we are looking at,
          # let's keep the ones from result
          set(_newresult ${_result})
          break()
          # list(APPEND _newresult ${_reslib})
        else()
          cuda_rdc_depends_on(_depends_on ${_lib} ${_reslib})
          if(${_depends_on})
            # We are in the opposite case, let's keep the library we are looking at
            list(APPEND _newresult ${_lib})
          else()
            # Unrelated keep both
            list(APPEND _newresult ${_reslib})
            list(APPEND _newresult ${_lib})
          endif()
        endif()
      endforeach()
      set(_result ${_newresult})
    endif()
  endforeach()
  list(REMOVE_DUPLICATES _result)
  set(_final_result "")
  foreach(_lib ${_result})
    if(TARGET ${_lib})
      get_target_property(_lib_target_type ${_lib} TYPE)
      if(NOT "x${_lib_target_type}" STREQUAL "xINTERFACE_LIBRARY")
        get_target_property(_final_lib ${_lib} CUDA_RDC_FINAL_LIBRARY)
        if(_final_lib)
          list(APPEND _final_result ${_final_lib})
        endif()
      endif()
    endif()
  endforeach()
  set(${OUTLIST} ${_final_result} PARENT_SCOPE)
endfunction()

# Replacement for target_link_libraries that is aware of
# the 3 libraries (static, middle, final) libraries needed
# for a separatable CUDA library
function(cuda_rdc_target_link_libraries target)
  if(NOT CMAKE_CUDA_COMPILER)
    target_link_libraries(${ARGV})
  else()
    cuda_rdc_strip_alias(target ${target})

    cuda_rdc_lib_contains_cuda(_contains_cuda ${target})

    set(_target_final ${target})
    set(_target_middle ${target})
    if (_contains_cuda)
      get_target_property(_targettype ${target} CUDA_RDC_LIBRARY_TYPE)
      if(_targettype)
        get_target_property(_target_final ${target} CUDA_RDC_FINAL_LIBRARY)
        get_target_property(_target_middle ${target} CUDA_RDC_MIDDLE_LIBRARY)
        get_target_property(_target_object ${target} CUDA_RDC_OBJECT_LIBRARY)
      endif()
    endif()

    # Set now to let target_link_libraries do the argument parsing
    target_link_libraries(${_target_middle} ${ARGN})

    cuda_rdc_use_middle_lib_in_property(${_target_middle} INTERFACE_LINK_LIBRARIES)
    cuda_rdc_use_middle_lib_in_property(${_target_middle} LINK_LIBRARIES)

    if(_target_object)
      target_link_libraries(${_target_object} ${ARGN})
      cuda_rdc_use_middle_lib_in_property(${_target_object} INTERFACE_LINK_LIBRARIES)
      cuda_rdc_use_middle_lib_in_property(${_target_object} LINK_LIBRARIES)
    endif()

    get_target_property(_target_type ${target} TYPE)
    if("x${_target_type}" STREQUAL "xEXECUTABLE")
      cuda_rdc_cuda_gather_dependencies(_alldependencies ${target})
      cuda_rdc_find_final_library(_finallibs "${_alldependencies}")
      list(LENGTH _finallibs _final_count)
      if(_contains_cuda)
        if(${_final_count} GREATER 0)
          # If there is at least one final library this means that we
          # have somewhere some "separable" nvcc compilations
          set_target_properties(${target} PROPERTIES
            CUDA_SEPARABLE_COMPILATION ON
          )
        endif()
      elseif(${_final_count} EQUAL 1)
        set_target_properties(${target} PROPERTIES
          # If cmake detects that a library depends/uses a static library
          # linked with CUDA, it will turn CUDA_RESOLVE_DEVICE_SYMBOLS ON
          # leading to a call to nvlink.  If we let this through (at least
          # in case of Celeritas) we would need to add the DEVICE_LINK options
          # also on non cuda libraries (that we detect depends on a cuda library).
          # Note: we might be able to move this to cuda_rdc_target_link_libraries
          CUDA_RESOLVE_DEVICE_SYMBOLS OFF
        )
        get_target_property(_final_target_type ${target} TYPE)
        if("x${_final_target_type}" STREQUAL "xSTATIC_LIBRARY")
          # for static libraries we need to list the libraries a second time (to resolve symbol from the final library)
          get_target_property(_current_link_libraries ${target} LINK_LIBRARIES)
          set_property(TARGET ${target} PROPERTY LINK_LIBRARIES ${_current_link_libraries} ${_finallibs} ${_current_link_libraries} )
        else()
          target_link_libraries(${target} PUBLIC ${_finallibs})
        endif()
      elseif(${_final_count} GREATER 1)
        # turn into CUDA executable.
        set(_contains_cuda TRUE)
        cuda_rdc_generate_empty_cu_file(_emptyfilename ${target})
        target_sources(${target} PRIVATE ${_emptyfilename})
      endif()
      # nothing to do if there is no final library (i.e. no use of CUDA at all?)
    endif()

    if(_contains_cuda)
      get_target_property(_current_runtime_setting ${target} CUDA_RUNTIME_LIBRARY)
      if(_current_runtime_setting)
         set(_target_runtime_setting ${_current_runtime_setting})
      endif()
      cuda_rdc_cuda_gather_dependencies(_flat_target_link_libraries ${_target_middle})
      foreach(_lib ${_flat_target_link_libraries})
        get_target_property(_lib_target_type ${_lib} TYPE)
        if(NOT "x${_lib_target_type}" STREQUAL "xINTERFACE_LIBRARY")
          get_target_property(_lib_runtime_setting ${_lib} CUDA_RUNTIME_LIBRARY)
          if(NOT _target_runtime_setting)
            if(_lib_runtime_setting)
              set(_target_runtime_setting ${_lib_runtime_setting})
            endif()
          else()
            if(_lib_runtime_setting AND NOT (_target_runtime_setting STREQUAL _lib_runtime_setting))
              if (_current_runtime_setting AND NOT (_current_runtime_setting STREQUAL _lib_runtime_setting))
                message(FATAL_ERROR "The CUDA runtime used for ${_lib} [${_lib_runtime_setting}] is different from the one used by ${target} [${_current_runtime_setting}]")
              else()
                message(FATAL_ERROR "The CUDA runtime used for ${_lib} [${_lib_runtime_setting}] is different from the one used by of the other dependency of ${target} [${_lib_runtime_setting}]")
              endif()
            endif()
          endif()
          if (NOT _current_runtime_setting)
             set_target_properties(${target} PROPERTIES CUDA_RUNTIME_LIBRARY ${_target_runtime_setting})
          endif()
          get_target_property(_libstatic ${_lib} CUDA_RDC_STATIC_LIBRARY)
          if(TARGET ${_libstatic})
            target_link_options(${_target_final}
              PRIVATE
              $<DEVICE_LINK:$<TARGET_FILE:${_libstatic}>>
            )

            # Also pass on the the options and definitions.
            cuda_rdc_transfer_setting(${_libstatic} ${_target_final} COMPILE_OPTIONS)
            cuda_rdc_transfer_setting(${_libstatic} ${_target_final} COMPILE_DEFINITIONS)
            cuda_rdc_transfer_setting(${_libstatic} ${_target_final} LINK_OPTIONS)

            add_dependencies(${_target_final} ${_libstatic})
          endif()
        endif()
      endforeach()
    else() # We could restrict to the case where the dependent is a static library ... maybe
      set_target_properties(${target} PROPERTIES
        # If cmake detects that a library depends/uses a static library
        # linked with CUDA, it will turn CUDA_RESOLVE_DEVICE_SYMBOLS ON
        # leading to a call to nvlink.  If we let this through (at least
        # in case of Celeritas) we would need to add the DEVICE_LINK options
        # also on non cuda libraries (that we detect depends on a cuda library).
        # Note: we might be able to move this to cuda_rdc_target_link_libraries
        CUDA_RESOLVE_DEVICE_SYMBOLS OFF
      )
    endif()
  endif()

endfunction()

#
# Return a flat list of all the direct and indirect dependencies of 'target'
# which are libraries containing CUDA separatable code.
#
function(cuda_rdc_cuda_gather_dependencies outlist target)
  if(TARGET ${target})
    cuda_rdc_strip_alias(target ${target})
    get_target_property(_target_type ${target} TYPE)
    if(NOT "x${_target_type}" STREQUAL "xINTERFACE_LIBRARY")
      get_target_property(_target_link_libraries ${target} LINK_LIBRARIES)
      if(_target_link_libraries)
        foreach(_lib ${_target_link_libraries})
          cuda_rdc_strip_alias(_lib ${_lib})
          if(TARGET ${_lib})
            cuda_rdc_get_library_middle_target(_libmid ${_lib})
          endif()
          if(TARGET ${_libmid})
            list(APPEND ${outlist} ${_libmid})
          endif()
          # and recurse
          cuda_rdc_cuda_gather_dependencies(_midlist ${_lib})
          list(APPEND ${outlist} ${_midlist})
        endforeach()
      endif()
    endif()
    list(REMOVE_DUPLICATES ${outlist})
    set(${outlist} ${${outlist}} PARENT_SCOPE)
  endif()
endfunction()


#-----------------------------------------------------------------------------#
