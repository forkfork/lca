local dir=arg[0]:match('^(.*)/')
package.path=dir..'/?.lua;'..package.path
local lifecycle=require('lifecycle')
os.exit(lifecycle.publish(assert(arg[1]),assert(arg[2]),assert(arg[3])) and 0 or 75)
