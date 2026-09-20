#include "range_control.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    range_control_t c;
    range_control_reset(&c, 40);
    for (int i=0;i<2000;i++) assert(range_control_tick(&c,i%3==0,25,75,0,10)==40);
    assert(c.locked);
    range_control_reset(&c,62);
    assert(range_control_tick(&c,0,10,30,100,30)==62);
    assert(range_control_tick(&c,0,10,30,100,30)==58);
    assert(range_control_tick(&c,0,10,30,100,30)==58);
    assert(range_control_tick(&c,0,10,30,100,30)==54);
    range_control_reset(&c,40);
    for(int i=0;i<20;i++) range_control_tick(&c,i%3==0,10,60,0,10);
    assert(c.trial && c.gain==42);
    for(int i=0;i<20;i++) range_control_tick(&c,0,10,20,0,100);
    assert(!c.trial && c.gain==40 && c.cooldown>=80);
    range_control_reset(&c,62);
    bool reached_low=false;
    for(int i=0;i<1000;i++) {
        uint8_t g=range_control_tick(&c,0,25,70,0,10);
        assert(g>=2 && g<=62);
        reached_low |= g<=8;
        assert(!c.locked);
    }
    assert(reached_low);
    range_control_reset(&c,24);
    assert(!c.trial && !c.cooldown && !c.failures && c.gain==24);
    puts("Range controller: stable hold, emergency cut, rollback, noise recovery and reset passed");
}
