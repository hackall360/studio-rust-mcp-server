use color_eyre::eyre::{eyre, Result, WrapErr};
use color_eyre::Help;
use roblox_install::RobloxStudio;
use serde_json::{json, Value};
use std::fs::File;
use std::io::BufReader;
use std::io::Write;
use std::path::Path;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};
use std::{env, fs, io};

fn install_plugin() -> Result<()> {
    let plugin_bytes = include_bytes!(concat!(env!("OUT_DIR"), "/MCPStudioPlugin.rbxm"));
    let studio = RobloxStudio::locate()?;
    let plugins = studio.plugins_path();
    if let Err(err) = fs::create_dir(plugins) {
        if err.kind() != io::ErrorKind::AlreadyExists {
            return Err(err.into());
        }
    }
    let output_plugin = Path::new(&plugins).join("MCPStudioPlugin.rbxm");
    {
        let mut file = File::create(&output_plugin).wrap_err_with(|| {
            format!(
                "Could write Roblox Plugin file at {}",
                output_plugin.display()
            )
        })?;
        file.write_all(plugin_bytes)?;
    }
    println!(
        "Installed Roblox Studio plugin to {}",
        output_plugin.display()
    );
    Ok(())
}

fn install_claude(exe_path: &Path) -> Result<&'static str> {
    install_to_config(get_claude_config(), exe_path, "Claude")
}

fn install_cursor(exe_path: &Path) -> Result<&'static str> {
    install_to_config(get_cursor_config(), exe_path, "Cursor")
}

fn get_lm_studio_config() -> Result<PathBuf> {
    if cfg!(target_os = "macos") {
        let home_dir =
            env::var_os("HOME").ok_or_else(|| eyre!("Could not determine HOME directory"))?;
        Ok(Path::new(&home_dir)
            .join("Library")
            .join("Application Support")
            .join("LM Studio")
            .join("mcpServers.json"))
    } else if cfg!(target_os = "windows") {
        let app_data =
            env::var_os("APPDATA").ok_or_else(|| eyre!("Could not find APPDATA directory"))?;
        Ok(Path::new(&app_data)
            .join("LM Studio")
            .join("mcpServers.json"))
    } else {
        let home_dir =
            env::var_os("HOME").ok_or_else(|| eyre!("Could not determine HOME directory"))?;
        Ok(Path::new(&home_dir)
            .join(".config")
            .join("LM Studio")
            .join("mcpServers.json"))
    }
}

fn install_lm_studio(exe_path: &Path) -> Result<&'static str> {
    install_to_config(get_lm_studio_config(), exe_path, "LM Studio")?;
    install_lm_studio_plugin_files(exe_path)?;
    Ok("LM Studio")
}

fn install_lm_studio_plugin_files(exe_path: &Path) -> Result<()> {
    let plugin_dir = get_lm_studio_plugin_dir()?;
    fs::create_dir_all(&plugin_dir).wrap_err_with(|| {
        format!(
            "Failed to create LM Studio plugin directory at {}",
            plugin_dir.display()
        )
    })?;

    let manifest_path = plugin_dir.join("manifest.json");
    write_json_file(
        &manifest_path,
        &json!({
            "type": "plugin",
            "runner": "mcpBridge",
            "owner": "mcp",
            "name": "roblox-studio"
        }),
    )?;

    let bridge_config_path = plugin_dir.join("mcp-bridge-config.json");
    write_json_file(
        &bridge_config_path,
        &json!({
            "command": exe_path,
            "args": ["--stdio"],
        }),
    )?;

    let install_state_path = plugin_dir.join("install-state.json");
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    write_json_file(
        &install_state_path,
        &json!({
            "by": "mcp-bridge-v1",
            "at": now,
        }),
    )?;

    println!(
        "Installed MCP Studio plugin to LM Studio plugin directory at {}",
        plugin_dir.display()
    );

    Ok(())
}

fn write_json_file(path: &Path, value: &Value) -> Result<()> {
    let mut file = File::create(path)
        .wrap_err_with(|| format!("Failed to create LM Studio file at {}", path.display()))?;
    file.write_all(serde_json::to_string_pretty(value)?.as_bytes())
        .wrap_err_with(|| format!("Failed to write LM Studio file at {}", path.display()))?;
    Ok(())
}

fn get_lm_studio_plugin_dir() -> Result<PathBuf> {
    let home_dir = lm_studio_home_dir()?;
    Ok(home_dir
        .join(".lmstudio")
        .join("extensions")
        .join("plugins")
        .join("mcp")
        .join("roblox-studio"))
}

fn lm_studio_home_dir() -> Result<PathBuf> {
    #[cfg(target_os = "windows")]
    {
        env::var_os("USERPROFILE")
            .or_else(|| env::var_os("HOME"))
            .map(PathBuf::from)
            .ok_or_else(|| eyre!("Could not determine LM Studio home directory"))
    }

    #[cfg(not(target_os = "windows"))]
    {
        env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or_else(|| eyre!("Could not determine LM Studio home directory"))
    }
}

fn get_message(successes: String) -> String {
    format!("Roblox Studio MCP is ready to go.
Please restart Studio and MCP clients to apply the changes.

MCP Clients set up:
{successes}

Note: connecting a third-party LLM to Roblox Studio via an MCP server will share your data with that external service provider. Please review their privacy practices carefully before proceeding.
To uninstall, delete the MCPStudioPlugin.rbxm from your Plugins directory.")
}

// returns OS dependant claude_desktop_config.json path
fn get_claude_config() -> Result<PathBuf> {
    let home_dir = env::var_os("HOME");

    let config_path = if cfg!(target_os = "macos") {
        Path::new(&home_dir.unwrap())
            .join("Library/Application Support/Claude/claude_desktop_config.json")
    } else if cfg!(target_os = "windows") {
        let app_data =
            env::var_os("APPDATA").ok_or_else(|| eyre!("Could not find APPDATA directory"))?;
        Path::new(&app_data)
            .join("Claude")
            .join("claude_desktop_config.json")
    } else {
        return Err(eyre!("Unsupported operating system"));
    };

    Ok(config_path)
}

fn get_cursor_config() -> Result<PathBuf> {
    let home_dir = env::var_os("HOME")
        .or_else(|| env::var_os("USERPROFILE"))
        .unwrap();
    Ok(Path::new(&home_dir).join(".cursor").join("mcp.json"))
}

#[cfg(target_os = "macos")]
fn get_exe_path() -> Result<PathBuf> {
    use core_foundation::url::CFURL;

    let local_path = env::current_exe()?;
    let local_path_cref = CFURL::from_path(local_path, false).unwrap();
    let un_relocated = security_translocate::create_original_path_for_url(local_path_cref.clone())
        .or_else(move |_| Ok::<CFURL, io::Error>(local_path_cref.clone()))?;
    let ret = un_relocated.to_path().unwrap();
    Ok(ret)
}

#[cfg(not(target_os = "macos"))]
fn get_exe_path() -> io::Result<PathBuf> {
    env::current_exe()
}

pub fn install_to_config<'a>(
    config_path: Result<PathBuf>,
    exe_path: &Path,
    name: &'a str,
) -> Result<&'a str> {
    let config_path = config_path?;
    let mut config: serde_json::Map<String, Value> = {
        if !config_path.exists() {
            let mut file = File::create(&config_path).map_err(|e| {
                eyre!("Could not create {name} config file at {config_path:?}: {e:#?}")
            })?;
            file.write_all(serde_json::to_string(&serde_json::Map::new())?.as_bytes())?;
        }
        let config_file = File::open(&config_path)
            .map_err(|error| eyre!("Could not read or create {name} config file: {error:#?}"))?;
        let reader = BufReader::new(config_file);
        serde_json::from_reader(reader)?
    };

    if !matches!(config.get("mcpServers"), Some(Value::Object(_))) {
        config.insert("mcpServers".to_string(), json!({}));
    }

    config["mcpServers"]["Roblox Studio"] = json!({
      "command": &exe_path,
      "args": [
        "--stdio"
      ]
    });

    let mut file = File::create(&config_path)?;
    file.write_all(serde_json::to_string_pretty(&config)?.as_bytes())
        .map_err(|e| eyre!("Could not write to {name} config file at {config_path:?}: {e:#?}"))?;

    println!("Installed MCP Studio plugin to {name} config {config_path:?}");

    Ok(name)
}

async fn install_internal() -> Result<String> {
    install_plugin()?;
    let this_exe = get_exe_path()?;

    let mut errors = vec![];
    let results = [
        install_claude(&this_exe),
        install_cursor(&this_exe),
        install_lm_studio(&this_exe),
    ];

    let successes: Vec<_> = results
        .into_iter()
        .filter_map(|r| r.map_err(|e| errors.push(e)).ok())
        .collect();

    if successes.is_empty() {
        let error = errors.into_iter().fold(
            eyre!("Failed to install to any supported MCP clients"),
            |report, e| report.note(e),
        );
        return Err(error);
    }

    println!();
    let msg = get_message(successes.join("\n"));
    println!("{msg}");
    Ok(msg)
}

pub async fn studio_install() -> Result<()> {
    use dialoguer::{theme::ColorfulTheme, Select};

    const OPTIONS: [&str; 5] = [
        "Install/Update Studio Plugin",
        "Install/Update Claude MCP connection",
        "Install/Update Cursor MCP connection",
        "Install/Update LM Studio MCP plugin",
        "Exit",
    ];

    let theme = ColorfulTheme::default();

    loop {
        let selection = Select::with_theme(&theme)
            .with_prompt("Select an action to perform")
            .items(&OPTIONS)
            .default(0)
            .interact_opt()?;

        let Some(selection) = selection else {
            println!("Exiting installer.");
            break;
        };

        let label = OPTIONS[selection];
        match selection {
            0 => run_task(label, || install_plugin()),
            1 => run_task(label, || {
                let exe = get_exe_path()?;
                install_claude(&exe).map(|_| ())
            }),
            2 => run_task(label, || {
                let exe = get_exe_path()?;
                install_cursor(&exe).map(|_| ())
            }),
            3 => run_task(label, || {
                let exe = get_exe_path()?;
                install_lm_studio(&exe).map(|_| ())
            }),
            4 => {
                println!("Exiting installer.");
                break;
            }
            _ => unreachable!(),
        }
    }

    Ok(())
}

fn run_task<F>(label: &str, task: F)
where
    F: FnOnce() -> Result<()>,
{
    match task() {
        Ok(_) => println!("{label} completed successfully.\n"),
        Err(error) => {
            eprintln!("{label} failed: {error:#}");
            println!();
        }
    }
}

#[cfg(target_os = "windows")]
pub async fn install() -> Result<()> {
    use std::process::Command;
    if let Err(e) = install_internal().await {
        tracing::error!("Failed initialize Roblox MCP: {:#}", e);
    }
    let _ = Command::new("cmd.exe").arg("/c").arg("pause").status();
    Ok(())
}

#[cfg(target_os = "macos")]
pub async fn install() -> Result<()> {
    use native_dialog::{DialogBuilder, MessageLevel};
    let alert_builder = match install_internal().await {
        Err(e) => DialogBuilder::message()
            .set_level(MessageLevel::Error)
            .set_text(format!("Errors occurred: {e:#}")),
        Ok(msg) => DialogBuilder::message()
            .set_level(MessageLevel::Info)
            .set_text(msg),
    };
    let _ = alert_builder.set_title("Roblox Studio MCP").alert().show();
    Ok(())
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
pub async fn install() -> Result<()> {
    install_internal().await?;
    Ok(())
}
