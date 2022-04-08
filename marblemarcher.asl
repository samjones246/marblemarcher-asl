state("Marble Marcher")
{
    
}

startup
{
    vars.Log = (Action<object>)((output) => print("[Process ASL] " + output));

    
}

init
{
    
}

start
{
    return false;
}

split
{
    return false;
}

reset
{
    return false;
}

shutdown
{
    
}