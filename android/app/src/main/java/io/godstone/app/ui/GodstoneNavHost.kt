package io.godstone.app.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.Chat
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import io.godstone.app.ui.browse.BrowseScreen
import io.godstone.app.ui.home.HomeScreen
import io.godstone.app.ui.mesh.MeshScreen
import io.godstone.app.ui.oracle.OracleScreen
import io.godstone.app.ui.sos.SosScreen
import io.godstone.mesh.MeshNode

/**
 * Five destinations, flat hierarchy. Under stress nobody navigates a tree.
 * Every screen is reachable in at most two taps from anywhere.
 */
sealed class Dest(val route: String, val label: String) {
    data object Home : Dest("home", "Home")
    data object Oracle : Dest("oracle", "Ask")
    data object Browse : Dest("browse", "Archive")
    data object Mesh : Dest("mesh", "Mesh")
    data object Sos : Dest("sos", "SOS")
}

@Composable
fun GodstoneNavHost(meshNode: MeshNode) {
    val nav = rememberNavController()
    val backStack by nav.currentBackStackEntryAsState()
    val current = backStack?.destination?.route

    Scaffold(
        bottomBar = {
            NavigationBar {
                listOf(Dest.Home, Dest.Oracle, Dest.Browse, Dest.Mesh, Dest.Sos)
                    .forEach { dest ->
                        NavigationBarItem(
                            selected = current == dest.route,
                            onClick = {
                                nav.navigate(dest.route) {
                                    popUpTo(Dest.Home.route)
                                    launchSingleTop = true
                                }
                            },
                            icon = { Icon(iconFor(dest), contentDescription = dest.label) },
                            label = { Text(dest.label) }
                        )
                    }
            }
        }
    ) { padding ->
        NavHost(
            navController = nav,
            startDestination = Dest.Home.route,
            modifier = androidx.compose.ui.Modifier.padding(padding)
        ) {
            composable(Dest.Home.route) { HomeScreen(onNavigate = { nav.navigate(it) }) }
            composable(Dest.Oracle.route) { OracleScreen() }
            composable(Dest.Browse.route) { BrowseScreen() }
            composable(Dest.Mesh.route) { MeshScreen(meshNode = meshNode) }
            composable(Dest.Sos.route) { SosScreen(meshNode = meshNode) }
        }
    }
}

private fun iconFor(dest: Dest) = when (dest) {
    Dest.Home -> Icons.Filled.Home
    Dest.Oracle -> Icons.Filled.Chat
    Dest.Browse -> Icons.Filled.Book
    Dest.Mesh -> Icons.Filled.Chat
    Dest.Sos -> Icons.Filled.Warning
}
