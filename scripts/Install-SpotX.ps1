# Installs/updates the SpotX Spotify mod (https://spotxapp.com) from the official
# SpotX-Official/SpotX repo main branch. Flags: uninstall Microsoft's Spotify app,
# prefer SpotX over it, podcasts off, block auto-updates, launch Spotify, new theme,
# ad sections off, lyrics enabled, spotify stats.
iex "& { $(iwr -useb 'https://raw.githubusercontent.com/SpotX-Official/SpotX/refs/heads/main/run.ps1') } -confirm_uninstall_ms_spoti -confirm_spoti_recomended_over -podcasts_off -block_update_on -start_spoti -new_theme -adsections_off -lyrics_stat spotify"