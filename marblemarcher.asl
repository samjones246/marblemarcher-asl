state("MarbleMarcher", "orig"){}

state("MarbleMarcher", "ce"){}

startup
{
    // For logging (duh)
    vars.Log = (Action<object>)((output) => print("[Marble Marcher ASL] " + output));

    // Function for deallocating memory used by this process
    vars.FreeMemory = (Action<Process>)(p => {
        vars.Log("Deallocating");
        foreach (IDictionary<string, object> hook in vars.hooks){
            if(((bool)hook["enabled"]) == false){
                continue;
            }
            p.FreeMemory((IntPtr)hook["outputPtr"]);
            p.FreeMemory((IntPtr)hook["funcPtr"]);
        }
    });

    vars.hooks = new List<ExpandoObject> {
        (vars.updateCamera = new ExpandoObject()),
    };

    // The updateCamera function will give us a pointer to the scene object
    // From there we can get the sum_time (gameTime) and cam_mode (gameState) properties
    vars.updateCamera.name = "UpdateCamera";
    vars.updateCamera.outputSize = 8;
    vars.updateCamera.overwriteBytes = 5;
    vars.updateCamera.payload = new byte[] { 0x48, 0x89, 0x08 }; // mov [rax], rcx
    vars.updateCamera.enabled = true;
}

init {
    vars.Log(modules.First().ModuleMemorySize.ToString("X"));
    if(modules.First().ModuleMemorySize == 0x231000){
        version = "orig";
    }else{
        version = "ce";
    }
    vars.updateCamera.offset = version == "orig" ? 0xC6A0 : 0x1D4C0;
    int gameTimeOffset = version == "orig" ? 0x190 : 0x548;
    int gameStateOffset = version == "orig" ? 0xD8 : 0x508;
    IntPtr baseAddress = modules.First().BaseAddress;
    // Install hooks
    foreach (IDictionary<string, object> hook in vars.hooks)
    {
        if(((bool)hook["enabled"]) == false){
            continue;
        }
        vars.Log("Installing hook for " + hook["name"]);

        // Get pointer to function
        hook["injectPtr"] = baseAddress + (int)hook["offset"];

        // Find nearby 12 byte code cave to store long jmp
        int caveSize = 0;
        int dist = 0;
        hook["cavePtr"] = IntPtr.Zero;
        vars.Log("Scanning for code cave");
        for(int i=1;i<0xFFFFFFFF;i++){
            byte b = game.ReadBytes((IntPtr)hook["injectPtr"] + i, 1)[0];
            if (b == 0xCC){
                caveSize++;
                if (caveSize == 12){
                    hook["caveOffset"] = i - 11;
                    hook["cavePtr"] = (IntPtr)hook["injectPtr"] + (int)hook["caveOffset"];
                    break;
                }
            }else{
                caveSize = 0;
            }
        }
        if ((IntPtr)hook["cavePtr"] == IntPtr.Zero){
            throw new Exception("Unable to locate nearby code cave");
        }
        vars.Log("Found cave " + ((int)hook["caveOffset"]).ToString("X") + " bytes away");

        // Allocate memory for output
        hook["outputPtr"] = game.AllocateMemory((int)hook["outputSize"]);

        // Build the hook function
        var funcBytes = new List<byte>() { 0x48, 0xB8 }; // mov rax, ...
        funcBytes.AddRange(BitConverter.GetBytes((UInt64)((IntPtr)hook["outputPtr"]))); // ...outputPtr
        funcBytes.AddRange((byte[])hook["payload"]);

        // Allocate memory to store the function
        hook["funcPtr"] = game.AllocateMemory(funcBytes.Count + (int)hook["overwriteBytes"] + 12);

        // Write the detour:
        // - Copy bytes from the start of original function which will be overwritten
        // - Overwrite those bytes with a 5 byte jump instruction to a nearby code cave
        // - In the code cave, write a 12 byte jump to the memory allocated for our hook function
        // - Write the hook function
        // - Write a copy of the overwritten code at the end of the hook function
        // - Following this, write a jump back the original function
        game.Suspend();
        try {
            // Copy the bytes which will be overwritten
            byte[] overwritten = game.ReadBytes((IntPtr)hook["injectPtr"], (int)hook["overwriteBytes"]);

            // Write short jump to code cave
            List<byte> caveJump = new List<byte>() { 0xE9 }; // jmp ...
            caveJump.AddRange(BitConverter.GetBytes((int)hook["caveOffset"] - 5)); // ...caveOffset - 5
            game.WriteBytes((IntPtr)hook["injectPtr"], caveJump.ToArray());
            hook["origBytes"] = overwritten;

            // NOP out excess bytes
            for(int i=0;i<(int)hook["overwriteBytes"]-5;i++){
                game.WriteBytes((IntPtr)hook["injectPtr"] + 5 + i, new byte[] { 0x90 });
            }

            // Write jump to hook function in code cave
            game.WriteJumpInstruction((IntPtr)hook["cavePtr"], (IntPtr)hook["funcPtr"]);

            // Write the hook function
            game.WriteBytes((IntPtr)hook["funcPtr"], funcBytes.ToArray());

            // Write the overwritten code
            game.WriteBytes((IntPtr)hook["funcPtr"] + funcBytes.Count, overwritten);

            // Write the jump to the original function
            game.WriteJumpInstruction((IntPtr)hook["funcPtr"] + funcBytes.Count + (int)hook["overwriteBytes"], (IntPtr)hook["injectPtr"] + (int)hook["overwriteBytes"]);
        }
        catch {
            vars.FreeMemory(game);
            throw;
        }
        finally{
            game.Resume();
        }

        // Calcuate offset of injection point from module base address
        UInt64 offset = (UInt64)((IntPtr)hook["injectPtr"]) - (UInt64)baseAddress;

        vars.Log("Output: " + ((IntPtr)hook["outputPtr"]).ToString("X"));
        vars.Log("Injection: " + ((IntPtr)hook["injectPtr"]).ToString("X") + " (GameAssembly.dll+" + offset.ToString("X") + ")");
        vars.Log("Function: " + ((IntPtr)hook["funcPtr"]).ToString("X"));
    }

    vars.Watchers = new MemoryWatcherList
    {
        (vars.gameTime = new MemoryWatcher<int>(new DeepPointer((IntPtr)vars.updateCamera.outputPtr, gameTimeOffset))),
        (vars.gameState = new MemoryWatcher<int>(new DeepPointer((IntPtr)vars.updateCamera.outputPtr, gameStateOffset)))
    };
}

update
{
    vars.Watchers.UpdateAll(game);
}

gameTime {
    double total_mills = (vars.gameTime.Current)*(16.66666666666);
    return new TimeSpan(0,0,0,0,Convert.ToInt32(total_mills));
}

isLoading
{
    return vars.gameTime.Current == vars.gameTime.Old;
}

start {
    return vars.gameState.Current == 2;
}

split
{
    return vars.gameState.Current == 5 && vars.gameState.Old != 5;   
}

reset
{
    return vars.gameState.Current == 0 && vars.gameState.Old != 0;
}

shutdown
{
    if (game == null)
        return;

    game.Suspend();
    try
    {
        vars.Log("Restoring memory");
        foreach (IDictionary<string, object> hook in vars.hooks){
            if(((bool)hook["enabled"]) == false){
                continue;
            }
            // Restore overwritten bytes
            game.WriteBytes((IntPtr)hook["injectPtr"], (byte[])hook["origBytes"]);

            // Remove jmp from code cave
            for(int i=0;i<12;i++){
                game.WriteBytes((IntPtr)hook["cavePtr"] + i, new byte[] { 0xCC });
            }

        }
        vars.Log("Memory restored");
    }
    catch
    {
        throw;
    }
    finally
    {
        game.Resume();
        vars.FreeMemory(game);
    }
}