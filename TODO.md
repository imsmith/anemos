# Here's where we stand against the spec:                                                                                                                                   
                                                                                                                                                               
  Fully working (60%)                                                                                                                                                                                                 
                                                                                  
  - ✅ Lexical structure (comments, strings, numbers, durations, sigils, identifiers)                                                                                                                                 
  - ✅ Rule, condition, capability declarations                
  - ✅ when blocks with compound events (OR/AND)                                                                                                                                                                      
  - ✅ at blocks (time literals, intervals, recurring schedules)                                                                                                                                                      
  - ✅ if/else/elseif (end-to-end tested)
  - ✅ when EV for <duration> { ... } — dwell-timer state machine
  - ✅ let, set, log, demand (with PAM flags), emit (with type/destination/label)                                                                                                                                     
  - ✅ [MODULE::verb] commands                                                                                                                                                                                        
  - ✅ Comparison and logical operators                                                                                                                                                                               
  - ✅ in, contains, starts_with, ends_with                                                                                                                                                                           
  - ✅ Context filtering, variable sigil differentiation                                                                                                                                                              
  - ✅ All three example files parse and run                                                                                                                                                                          
                                                                                                                                                                                                                      
  Partially implemented (25%)                                                                                                                                                                                         
                                                                                                                                                                                                                      
  -[x] ⚠️  Operator precedence — flat recursive descent, no full precedence table                                                                                                                                         
  -[x] ⚠️  Triple patterns — AST exists, no compilation/execution                                                                                                                                                         
  -[x] ⚠️  Messaging substrate — destinations parsed, no routing                                                                                                                                                          
  -[x] ⚠️  Message envelope — missing source, timestamp, signature                                                                                                                                                        
  -[x] ⚠️  NLD_ natural language dates — token reserved, not implemented                                                                                                                                                  
  -[x] ⚠️  Rule metadata (version, signed_by, scope) — keywords lexed, not parsed                                                                                                                                         
                                                                                                                                                                                                                      
  Not implemented (15%)                                                                                                                                                                                               
                                                                                                                                                                                                                      
  - ❌ Loops — while, for, each, every, foreach                                                                                                                                                                       
  - ❌ Flow control — nextevent, nextrule, return, done                                                                                                                                                               
  - ❌ Guards — unless, until                                                                                                                                                                                         
  - ❌ Pipelines — |> with filter, map, reduce                                                                                                                                                                        
  - ❌ Introspection — show, list, graph, trace, explain, exists, infer, assert                                                                                                                                       
  - ❌ it/on/as/with blocks — modal refs, invocation refs, group specs                                                                                                                                                
  - ❌ Flow declarations — flow, nextrule                                                                                                                                                                             
  - ❌ Bitwise operators — &, |, ^, ~, <<, >>                                                                                                                                                                         
  - ❌ Regex/string sigils — ~r, ~s                                                                                                                                                                                   
  - ❌ Size literals — KB, MB, GB, TB                                                                                                                                                                                 
  - ❌ Error handling — when ERROR { ... }                                                                                                                                                                            
  - ❌ systemd() destination                                                                                                                                                                                          
  - ❌ Hot reload — file watching  